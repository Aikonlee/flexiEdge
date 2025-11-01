/*
 * Copyright (c) 2015 Cisco and/or its affiliates.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at:
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 *  Copyright (C) 2021 flexiWAN Ltd.
 *  List of fixes and changes made for FlexiWAN - denoted by FLEXIWAN_FIX
 *  and FLEXIWAN_FEATURE flags:
 *   - rotate_pcap_capture : Extend the 'pcap trace' command to support
 *   the capturing of last x packets. This is made possible by making the
 *   pcap buffer to work as a preallocated circular buffer.
 */

#ifndef included_vppinfra_pcap_funcs_h
#define included_vppinfra_pcap_funcs_h

/** Write out data to output file. */
clib_error_t *pcap_close (pcap_main_t * pm);
clib_error_t *pcap_write (pcap_main_t * pm);

/** Read data from file. */
clib_error_t *pcap_read (pcap_main_t * pm);

/** Close the file created by pcap_write function. */
clib_error_t *pcap_close (pcap_main_t * pm);


#ifdef FLEXIWAN_FEATURE /* FLEXIWAN_FEATURE - rotate_pcap_capture */
/**
 * @brief Add packet to the circular pcap buffer
 *
 * @param *pm - pcap_main_t
 * @param time_now - f64
 * @param n_bytes_in_trace - u32
 * @param n_bytes_in_packet - u32
 *
 * @return Packet Data
 *
 */
static inline void *
pcap_add_packet_rotate (pcap_main_t * pm, u32 index, f64 time_now,
                        u32 n_bytes_in_trace, u32 n_bytes_in_packet)
{
  pcap_packet_header_t *h;
  uint32_t offset = (sizeof (h[0]) + pm->max_bytes_per_pkt) * index;
  h = (pcap_packet_header_t *)(pm->pcap_data + offset);

  h->time_in_sec = time_now;
  h->time_in_usec = 1e6 * (time_now - h->time_in_sec);
  h->n_packet_bytes_stored_in_file = n_bytes_in_trace;
  h->n_bytes_in_packet = n_bytes_in_packet;
  pm->n_packets_captured++;
  if (pm->n_packets_captured > pm->n_packets_to_capture)
    pm->n_packets_captured = pm->n_packets_to_capture;
  return h->data;
}

/**
 * @brief Add buffer (vlib_buffer_t) to the circular pcap trace
 *
 * @param *pm - pcap_main_t
 * @param *vm - vlib_main_t
 * @param buffer_index - u32
 *
 */
static inline void
pcap_add_buffer_rotate (pcap_main_t * pm,
                        struct vlib_main_t *vm, u32 buffer_index)
{
  vlib_buffer_t *b = vlib_get_buffer (vm, buffer_index);
  u32 n = vlib_buffer_length_in_chain (vm, b);
  i32 n_left = clib_min (pm->max_bytes_per_pkt, n);
  f64 time_now = vlib_time_now (vm);
  void *d;

  clib_spinlock_lock_if_init (&pm->lock);
  if (pm->n_packets_captured == pm->n_packets_to_capture)
    pm->buffer_read_index =
      (pm->buffer_read_index + 1) % pm->n_packets_to_capture;

  d = pcap_add_packet_rotate (pm, pm->buffer_write_index, time_now, n_left, n);
  while (1)
    {
      u32 copy_length = clib_min ((u32) n_left, b->current_length);
      clib_memcpy_fast (d, b->data + b->current_data, copy_length);

      n_left -= b->current_length;
      if (n_left <= 0)
        break;
      d += b->current_length;
      ASSERT (b->flags & VLIB_BUFFER_NEXT_PRESENT);
      b = vlib_get_buffer (vm, b->next_buffer);
    }
  pm->buffer_write_index =
    (pm->buffer_write_index + 1) % pm->n_packets_to_capture;

  clib_spinlock_unlock_if_init (&pm->lock);
}
#endif /* FLEXIWAN_FEATURE - rotate_pcap_capture */

/**
 * @brief Add packet
 *
 * @param *pm - pcap_main_t
 * @param time_now - f64
 * @param n_bytes_in_trace - u32
 * @param n_bytes_in_packet - u32
 *
 * @return Packet Data
 *
 */
static inline void *
pcap_add_packet (pcap_main_t * pm,
		 f64 time_now, u32 n_bytes_in_trace, u32 n_bytes_in_packet)
{
  pcap_packet_header_t *h;
  u8 *d;

  vec_add2 (pm->pcap_data, d, sizeof (h[0]) + n_bytes_in_trace);
  h = (void *) (d);
  h->time_in_sec = time_now;
  h->time_in_usec = 1e6 * (time_now - h->time_in_sec);
  h->n_packet_bytes_stored_in_file = n_bytes_in_trace;
  h->n_bytes_in_packet = n_bytes_in_packet;
  pm->n_packets_captured++;
  return h->data;
}

/**
 * @brief Add buffer (vlib_buffer_t) to the trace
 *
 * @param *pm - pcap_main_t
 * @param *vm - vlib_main_t
 * @param buffer_index - u32
 * @param n_bytes_in_trace - u32
 *
 */
static inline void
pcap_add_buffer (pcap_main_t * pm,
		 struct vlib_main_t *vm, u32 buffer_index,
		 u32 n_bytes_in_trace)
{
  vlib_buffer_t *b = vlib_get_buffer (vm, buffer_index);
  u32 n = vlib_buffer_length_in_chain (vm, b);
  i32 n_left = clib_min (n_bytes_in_trace, n);
  f64 time_now = vlib_time_now (vm);
  void *d;

#ifdef FLEXIWAN_FEATURE /* FLEXIWAN_FEATURE - rotate_pcap_capture */
  if (pm->circular_buffer)
    {
      pcap_add_buffer_rotate (pm, vm, buffer_index);
      return;
    }
#endif /* FLEXIWAN_FEATURE - rotate_pcap_capture */

  if (PREDICT_TRUE (pm->n_packets_captured < pm->n_packets_to_capture))
    {
      clib_spinlock_lock_if_init (&pm->lock);
      d = pcap_add_packet (pm, time_now, n_left, n);
      while (1)
	{
	  u32 copy_length = clib_min ((u32) n_left, b->current_length);
	  clib_memcpy_fast (d, b->data + b->current_data, copy_length);
	  n_left -= b->current_length;
	  if (n_left <= 0)
	    break;
	  d += b->current_length;
	  ASSERT (b->flags & VLIB_BUFFER_NEXT_PRESENT);
	  b = vlib_get_buffer (vm, b->next_buffer);
	}
      clib_spinlock_unlock_if_init (&pm->lock);
    }
}

#endif /* included_vppinfra_pcap_funcs_h */

/*
 * fd.io coding-style-patch-verification: ON
 *
 * Local Variables:
 * eval: (c-set-style "gnu")
 * End:
 */
