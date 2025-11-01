/*
 * Copyright (c) 2016 Cisco and/or its affiliates.
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
 *  Copyright (C) 2020 flexiWAN Ltd.
 *  This file is part of the FWABF plugin.
 *  The FWABF plugin is fork of the FDIO VPP ABF plugin.
 *  It enhances ABF with functionality required for Flexiwan Multi-Link feature.
 *  For more details see official documentation on the Flexiwan Multi-Link.
 *
 *  adding_fwabf_vpp_apis - Adding VPP VPI to dump the policy, label and link
 *  states and statistic values.
 */

#include <vnet/vnet.h>
#include <vnet/plugin/plugin.h>
#include <fwabf/fwabf_policy.h>
#include <fwabf/fwabf_links.h>

#include <vpp/app/version.h>
#include <vlibapi/api.h>
#include <vlibmemory/api.h>

/**
 * Base message ID fot the plugin
 */
static u32 fwabf_base_msg_id;
#define REPLY_MSG_ID_BASE fwabf_base_msg_id

/* define message IDs */
#include <fwabf/fwabf.api_enum.h>
#include <fwabf/fwabf.api_types.h>
#include <vlibapi/api_helper_macros.h>

#define FWABF_MAX_PER_POLICY_GROUP_LABELS (64)

extern fwabf_label_data_t* fwabf_labels;
extern fwabf_policy_t *abf_policy_pool;
extern fwabf_link_t *fwabf_links;

/*
 * The function dumps all the fwabf policy states and stats
 */
static void
vl_api_fwabf_policy_dump_t_handler(vl_api_fwabf_policy_dump_t * mp)
{
  vl_api_fwabf_policy_details_t *rmp;
  vl_api_registration_t *reg =
    vl_api_client_index_to_registration (mp->client_index);
  if (!reg)
    {
      clib_warning ("Client index to registration failed");
      return;
    }

  fwabf_policy_t *p;
  pool_foreach (p, abf_policy_pool)
    {
      u32 n_groups = vec_len (p->action.link_groups);
      u32 msg_size = sizeof (vl_api_fwabf_policy_details_t) +
        (n_groups * sizeof (vl_api_fwabf_policy_group_t));

      rmp = vl_msg_api_alloc (msg_size);
      clib_memset (rmp, 0, msg_size);
      rmp->_vl_msg_id = clib_net_to_host_u16
        (VL_API_FWABF_POLICY_DETAILS + fwabf_base_msg_id);
      rmp->context = mp->context;

      rmp->id = clib_host_to_net_u32 (p->id);
      rmp->acl_index = clib_host_to_net_u32 (p->acl);
      rmp->counter_matched = clib_host_to_net_u32 (p->counter_matched);
      rmp->counter_applied = clib_host_to_net_u32 (p->counter_applied);
      rmp->counter_fallback = clib_host_to_net_u32 (p->counter_fallback);
      rmp->counter_dropped = clib_host_to_net_u32 (p->counter_dropped);
      rmp->override_default_route = p->override_default_route;
      rmp->action_fallback = p->action.fallback;
      rmp->action_alg = p->action.alg;
      rmp->group_count = clib_host_to_net_u32 (n_groups);

      for (u32 i = 0; i < n_groups; i++)
        {
          fwabf_policy_link_group_t *link_group = &(p->action.link_groups[i]);
          rmp->groups[i].group_alg = link_group->alg;
          u32 n_links = vec_len (link_group->links);
          rmp->groups[i].label_count = clib_host_to_net_u32 (n_links);
          /*
           * if the label_count is > 64 then only the first 64 entries shall be
           * returned as response. The truncation can be detected on receiving
           * the response by checking if the label_count is > 64.
           */
          for (u32 j = 0;
               (j < n_links && j < FWABF_MAX_PER_POLICY_GROUP_LABELS); j++)
            {
              rmp->groups[i].labels[j] =
                clib_host_to_net_u32 ((u32) link_group->links[j]);
            }
        }

      vl_api_send_msg (reg, (u8 *) rmp);
    }
  return;
}

/*
 * The function dumps all the fwabf label states and stats
 */
static void
vl_api_fwabf_label_dump_t_handler (vl_api_fwabf_label_dump_t * mp)
{
  vl_api_fwabf_label_details_t *rmp;
  u32 msg_size;
  u32 sw_if_index_count;
  vl_api_registration_t *reg =
    vl_api_client_index_to_registration (mp->client_index);
  if (!reg)
    {
      clib_warning ("Client index to registration failed");
      return;
    }

  for (u32 i = 0; i < vec_len (fwabf_labels); i++)
    {
      fwabf_label_data_t *label = &fwabf_labels[i];
      sw_if_index_count = vec_len(label->interfaces);
      msg_size = sizeof(vl_api_fwabf_label_details_t) +
        (sw_if_index_count * sizeof(vl_api_interface_index_t));

      rmp = vl_msg_api_alloc (msg_size);
      clib_memset (rmp, 0, msg_size);
      rmp->_vl_msg_id = clib_net_to_host_u16
        (VL_API_FWABF_LABEL_DETAILS + fwabf_base_msg_id);
      rmp->context = mp->context;

      rmp->label = clib_host_to_net_u32 (i);
      rmp->hits = clib_host_to_net_u32 (label->counter_hits);
      rmp->misses = clib_host_to_net_u32 (label->counter_misses);
      rmp->enforced_hits = clib_host_to_net_u32 (label->counter_enforced_hits);
      rmp->enforced_misses =
        clib_host_to_net_u32 (label->counter_enforced_misses);
      rmp->quality_hits = clib_host_to_net_u32 (label->counter_quality_hits);
      rmp->quality_reduced_hits =
        clib_host_to_net_u32 (label->counter_quality_reduced_hits);

      for (u32 j = 0; j < sw_if_index_count; j++)
        rmp->sw_if_indexes[j] = clib_host_to_net_u32 (label->interfaces[j]);
      rmp->sw_if_index_count = clib_host_to_net_u32 (sw_if_index_count);

      vl_api_send_msg (reg, (u8 *) rmp);
    }
}

/*
 * The function dumps all the fwabf link states and stats
 */
static void
vl_api_fwabf_link_dump_t_handler (vl_api_fwabf_link_dump_t * mp)
{
  vl_api_fwabf_link_details_t *rmp;
  vl_api_registration_t *reg =
    vl_api_client_index_to_registration (mp->client_index);
  if (!reg)
    {
      clib_warning ("Client index to registration failed");
      return;
    }

  fwabf_link_t *link;
  vec_foreach (link, fwabf_links)
    {
      rmp = vl_msg_api_alloc (sizeof(vl_api_fwabf_link_details_t));
      clib_memset (rmp, 0, sizeof(*rmp));
      rmp->_vl_msg_id = clib_net_to_host_u16
        (VL_API_FWABF_LINK_DETAILS + fwabf_base_msg_id);
      rmp->context = mp->context;

      rmp->label = clib_host_to_net_u32 ((u32) link->fwlabel);
      rmp->loss = clib_host_to_net_u32 (link->quality.loss);
      rmp->delay = clib_host_to_net_u32 (link->quality.delay);
      rmp->jitter = clib_host_to_net_u32 (link->quality.jitter);
      rmp->dpoi_index = clib_host_to_net_u32 (link->dpo.dpoi_index);
      rmp->path_list_index = clib_host_to_net_u32 (link->pathlist_index);
      rmp->sw_if_index = clib_host_to_net_u32 (link->sw_if_index);

      vl_api_send_msg (reg, (u8 *) rmp);
    }
}

static void
vl_api_fwabf_policy_reset_stats_t_handler
(vl_api_fwabf_policy_reset_stats_t * mp)
{
  vl_api_fwabf_policy_reset_stats_reply_t *rmp;
  i32 rv = 0;

  fwabf_policy_t *p;
  pool_foreach (p, abf_policy_pool)
    {
      p->counter_matched = 0;
      p->counter_applied = 0;
      p->counter_fallback = 0;
      p->counter_dropped = 0;
    }

  REPLY_MACRO (VL_API_FWABF_POLICY_RESET_STATS_REPLY);
}

static void
vl_api_fwabf_label_reset_stats_t_handler
(vl_api_fwabf_label_reset_stats_t * mp)
{
  vl_api_fwabf_label_reset_stats_reply_t *rmp;
  i32 rv = 0;

  for (u32 i = 0; i < vec_len (fwabf_labels); i++)
    {
      fwabf_label_data_t *label = &fwabf_labels[i];
      label->counter_hits = 0;
      label->counter_misses = 0;
      label->counter_enforced_hits = 0;
      label->counter_enforced_misses = 0;
      label->counter_quality_hits = 0;
      label->counter_quality_reduced_hits = 0;
    }

  REPLY_MACRO (VL_API_FWABF_LABEL_RESET_STATS_REPLY);
}

#include <fwabf/fwabf.api.c>

static clib_error_t *
fwabf_api_init (vlib_main_t * vm)
{
  /* Set up the API message handling tables */
  fwabf_base_msg_id = setup_message_id_table ();

  return 0;
}

VLIB_INIT_FUNCTION (fwabf_api_init);


/* *INDENT-OFF* */
VLIB_PLUGIN_REGISTER () = {
    .version = VPP_BUILD_VER,
    .description = "Flexiwan Access Control List (ACL) Based Forwarding",
};
/* *INDENT-ON* */

/*
 * fd.io coding-style-patch-verification: ON
 *
 * Local Variables:
 * eval: (c-set-style "gnu")
 * End:
 */
