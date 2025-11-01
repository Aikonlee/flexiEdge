/*
 * Copyright (c) 2022 FlexiWAN
 *
 * List of features made for FlexiWAN (denoted by FLEXIWAN_FEATURE flag):
 *  - acl_based_classification: Feature to provide traffic classification using
 *  ACL plugin. Matching ACLs provide the service class and importance
 *  attribute. The classification result is marked in the packet and can be
 *  made use of in other functions like scheduling, policing, marking etc.
 *
 * This file is added by the Flexiwan feature: acl_based_classification.
 */

#include <vlib/vlib.h>
#include <vnet/vnet.h>
#include <vnet/pg/pg.h>
#include <vppinfra/error.h>
#include <vnet/policer/policer.h>
#include <vnet/policer/police_inlines.h>
#include <classifier_acls/classifier_acls.h>
#include <classifier_acls/inlines.h>

typedef struct
{
  u32 sw_if_index;
  u32 match_acl_index;
  u32 match_rule_index;
  u32 next_index;
  u32 policer_color;
  u8 match_flag;
  u8 service_class;
  u8 importance;
} classifier_acls_trace_t;

#ifndef CLIB_MARCH_VARIANT

/* packet trace format function */
static u8 * format_classifier_acls_trace (u8 * s, va_list * args)
{
  CLIB_UNUSED (vlib_main_t * vm) = va_arg (*args, vlib_main_t *);
  CLIB_UNUSED (vlib_node_t * node) = va_arg (*args, vlib_node_t *);
  classifier_acls_trace_t * t = va_arg (*args, classifier_acls_trace_t *);
  
  s = format (s, "CLASSIFIER_ACLS: sw_if_index: %u, match: %u, next_index: %u",
	      t->sw_if_index, t->match_flag, t->next_index);
  s = format (s, "\nacl_index: %u, rule_index: %u, service_class: %u, importance: %u",
	      t->match_acl_index, t->match_rule_index, t->service_class, t->importance);

  switch (t->policer_color)
    {
    case POLICE_CONFORM:
      s = format (s, "\n Policer color - POLICE_CONFORM");
      break;
    case POLICE_EXCEED:
      s = format (s, "\n Policer color - POLICE_EXCEED");
      break;
    case POLICE_VIOLATE:
      s = format (s, "\n Policer color - POLICE_VIOLATE");
      break;
    }
  return s;
}

#endif /* CLIB_MARCH_VARIANT */


#define foreach_classifier_acls_counter \
_(MATCHES, "acl matches") \
_(MISSES, "acl misses")   \
_(POLICER_INPUT, "policer_input") \
_(MEDIUM_POLICER_DROPS, "medium_policer_drops") \
_(LOW_POLICER_DROPS, "low_policer_drops")

typedef enum {
#define _(sym,str) CLASSIFIER_ACLS_##sym,
  foreach_classifier_acls_counter
#undef _
  CLASSIFIER_ACLS_N_COUNTER,
} classifier_acls_error_t;

#ifndef CLIB_MARCH_VARIANT
static char * classifier_acls_error_strings[] = 
{
#define _(sym,string) string,
  foreach_classifier_acls_counter
#undef _
};
#endif /* CLIB_MARCH_VARIANT */

typedef enum 
{
  CLASSIFIER_ACLS_NEXT_DROP,
  CLASSIFIER_ACLS_N_NEXT,
} classifier_acls_next_t;

/*
 * Check if the packet matches the ports configured to skip the classification
 */
always_inline u8
classifier_acls_intf_config_check_skip_port (vlib_buffer_t *b)
{
  ip4_header_t *ip4 = vlib_buffer_get_current (b);
  if ((ip4->protocol == IP_PROTOCOL_UDP) || (ip4->protocol == IP_PROTOCOL_TCP))
    {
      classifier_acls_main_t * cmp = &classifier_acls_main;
      classifier_skip_port_t skip_port = {
          .protocol = ip4->protocol,
          .port = vnet_buffer (b)->ip.reass.l4_dst_port,
          .reserved = 0
      };
      u64 skip_port_rule =
        ((u64)vnet_buffer (b)->sw_if_index[VLIB_RX] << 32) | skip_port.as_u32;
      uword * p = hash_get (cmp->skip_port_rules, skip_port_rule);
      if (p)
        return 1;
    }
  return 0;
}

always_inline uword
classifier_acls_node_inline (vlib_main_t * vm,
			     vlib_node_runtime_t * node,
			     vlib_frame_t * frame, u8 is_ip6)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 n_left_from, * from;
  classifier_acls_next_t next_index;
  u32 matches = 0;
  u32 misses = 0;
  u32 medium_policer_drops = 0;
  u32 low_policer_drops = 0;
  u32 policer_input = 0;
  u32 match_acl_index;
  u32 match_rule_index;

  from = vlib_frame_vector_args (frame);
  n_left_from = frame->n_vectors;
  next_index = node->cached_next_index;

  u64 time_in_policer_periods =
    clib_cpu_time_now () >> POLICER_TICKS_PER_PERIOD_SHIFT;
  classifier_intf_config_t *config = NULL; 
  u32 prev_sw_if_index = ~0;

  while (n_left_from > 0)
    {
      u32 n_left_to_next, * to_next;
      vlib_get_next_frame (vm, node, next_index,
			   to_next, n_left_to_next);

      while (n_left_from > 0 && n_left_to_next > 0)
	{
	  u32 bi0;
	  vlib_buffer_t * b0;
	  u32 next0;
	  u32 sw_if_index;
          policer_result_e col = POLICE_CONFORM; 
          match_acl_index = ~0;

	  /* speculatively enqueue b0 to the current next frame */
	  bi0 = from[0];
	  to_next[0] = bi0;
	  from += 1;
	  to_next += 1;
	  n_left_from -= 1;
	  n_left_to_next -= 1;
	  b0 = vlib_get_buffer (vm, bi0);
	  vnet_feature_next (&next0, b0);

	  sw_if_index = vnet_buffer (b0)->sw_if_index[VLIB_RX];
          if ((prev_sw_if_index == ~0) || (prev_sw_if_index != sw_if_index))
            {
              uword * p = hash_get (cmp->config_by_sw_if_index, sw_if_index);
              if (p)
                config = (classifier_intf_config_t *) p[0];
              prev_sw_if_index = sw_if_index;
            }

          if (!config)
            goto trace_pkt;

          if (config->policer_id != ~0)
            {
              policer_input++;
              vnet_policer_police (vm, b0, config->policer_id,
                                   time_in_policer_periods, POLICE_CONFORM);
            }

          // Skip classification if matches skip port
          if (classifier_acls_intf_config_check_skip_port (b0))
            goto trace_pkt;

          if (classifier_acls_classify_packet (b0, sw_if_index, is_ip6,
                                                   &match_acl_index,
                                                   &match_rule_index))
            matches++;
          else
            misses++;

          if (config->enable_drop_check)
            {
              col = vnet_buffer2 (b0)->qos.policer_mark;
              switch (col)
                {
                case POLICE_CONFORM:
                  // Drop not required
                  break;
                case POLICE_EXCEED:
                  if (vnet_buffer2 (b0)->qos.importance == 0)
                    {
                      // Drop only low priority
                      next0 = CLASSIFIER_ACLS_NEXT_DROP;
                      low_policer_drops++;
                    }
                  break;
                case POLICE_VIOLATE:
                  if (vnet_buffer2 (b0)->qos.importance <= 1)
                    {
                      // Drop both low and medium priority
                      next0 = CLASSIFIER_ACLS_NEXT_DROP;
                      if (vnet_buffer2 (b0)->qos.importance == 0)
                        low_policer_drops++;
                      if (vnet_buffer2 (b0)->qos.importance == 1)
                        medium_policer_drops++;
                    }
                  break;
                }
            }
          else
            vnet_buffer2 (b0)->qos.policer_mark = 0;

trace_pkt:
	  if (PREDICT_FALSE ((node->flags & VLIB_NODE_FLAG_TRACE)
			     && (b0->flags & VLIB_BUFFER_IS_TRACED)))
            {
              classifier_acls_trace_t *t = vlib_add_trace (vm, node, b0,
                                                           sizeof (*t));
              t->next_index = next0;
              t->sw_if_index = sw_if_index;
              t->match_flag = (match_acl_index != ~0) ? 1 : 0;
              t->service_class = vnet_buffer2 (b0)->qos.service_class;
              t->importance = vnet_buffer2 (b0)->qos.importance;
              t->match_acl_index = match_acl_index;
              t->match_rule_index = (t->match_flag) ? match_rule_index : ~0;
              t->policer_color = col;
            }
	  /* verify speculative enqueue, maybe switch current next frame */
	  vlib_validate_buffer_enqueue_x1 (vm, node, next_index,
					   to_next, n_left_to_next,
					   bi0, next0);
	}

      vlib_put_next_frame (vm, node, next_index, n_left_to_next);
    }

  if (matches)
    vlib_node_increment_counter (vm, node->node_index,
				 CLASSIFIER_ACLS_MATCHES, matches);

  if (misses)
    vlib_node_increment_counter (vm, node->node_index,
				 CLASSIFIER_ACLS_MISSES, misses);

  if (low_policer_drops)
    vlib_node_increment_counter (vm, node->node_index,
				 CLASSIFIER_ACLS_LOW_POLICER_DROPS,
                                 low_policer_drops);

  if (medium_policer_drops)
    vlib_node_increment_counter (vm, node->node_index,
				 CLASSIFIER_ACLS_MEDIUM_POLICER_DROPS,
                                 medium_policer_drops);

  if (policer_input)
    vlib_node_increment_counter (vm, node->node_index,
				 CLASSIFIER_ACLS_POLICER_INPUT,
                                 policer_input);

  return frame->n_vectors;
}


VLIB_NODE_FN (ip4_classifier_acls_node) (vlib_main_t * vm,
					 vlib_node_runtime_t * node,
					 vlib_frame_t * frame)
{
  return classifier_acls_node_inline (vm, node, frame, 0 /* is_ip6 */);

}

VLIB_NODE_FN (ip6_classifier_acls_node) (vlib_main_t * vm,
					 vlib_node_runtime_t * node,
					 vlib_frame_t * frame)
{
  return classifier_acls_node_inline (vm, node, frame, 1 /* is_ip6 */);
}

/* *INDENT-OFF* */
#ifndef CLIB_MARCH_VARIANT
VLIB_REGISTER_NODE (ip4_classifier_acls_node) = 
{
  .name = "ip4-classifier-acls",
  .vector_size = sizeof (u32),
  .format_trace = format_classifier_acls_trace,
  .type = VLIB_NODE_TYPE_INTERNAL,
  
  .n_errors = ARRAY_LEN(classifier_acls_error_strings),
  .error_strings = classifier_acls_error_strings,

  .n_next_nodes = CLASSIFIER_ACLS_N_NEXT,

  .next_nodes = {
        [CLASSIFIER_ACLS_NEXT_DROP] = "error-drop",
  },
};

VLIB_REGISTER_NODE (ip6_classifier_acls_node) = 
{
  .name = "ip6-classifier-acls",
  .vector_size = sizeof (u32),
  .format_trace = format_classifier_acls_trace,
  .type = VLIB_NODE_TYPE_INTERNAL,
  
  .n_errors = ARRAY_LEN(classifier_acls_error_strings),
  .error_strings = classifier_acls_error_strings,

  .n_next_nodes = CLASSIFIER_ACLS_N_NEXT,

  .next_nodes = {
        [CLASSIFIER_ACLS_NEXT_DROP] = "error-drop",
  },
};

#endif /* CLIB_MARCH_VARIANT */
/* *INDENT-ON* */
/*
 * fd.io coding-style-patch-verification: ON
 *
 * Local Variables:
 * eval: (c-set-style "gnu")
 * End:
 */
