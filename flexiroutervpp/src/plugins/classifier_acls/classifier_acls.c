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

/*
 * The plugin provides support to create a set of acl-lists that can be
 * identified by an unique integer index. The acl-list can then be attached to
 * an interface by passing the acl-list ID. This method limits the acl plugin
 * lookup context to a small configured count. This reduces the memory usage as
 * multiple interface attachments can reuse the same acl-list (i.e acl plugin
 * context)
 *
 * The classifier node can be optionally attached with a policer and perform
 * priority aware policing.
 */

#include <vnet/vnet.h>
#include <vnet/plugin/plugin.h>
#include <vnet/policer/policer.h>
#include <vnet/ip/reass/ip4_sv_reass.h>
#include <classifier_acls/classifier_acls.h>
#include <classifier_acls/inlines.h>

#include <vlibapi/api.h>
#include <vlibmemory/api.h>
#include <vpp/app/version.h>
#include <stdbool.h>

#include <classifier_acls/classifier_acls.api_enum.h>
#include <classifier_acls/classifier_acls.api_types.h>

#define REPLY_MSG_ID_BASE cmp->msg_id_base
#include <vlibapi/api_helper_macros.h>

classifier_acls_main_t classifier_acls_main;


/* enable_disable function shared between message handler and debug CLI */
static int
classifier_acls_enable_disable (classifier_acls_main_t * cmp, u32 sw_if_index,
				int enable_disable)
{
  int rv = -1;

  if (pool_is_free_index (cmp->vnet_main->interface_main.sw_interfaces,
                          sw_if_index))
    return VNET_API_ERROR_INVALID_SW_IF_INDEX;

  uword * p = hash_get (cmp->config_by_sw_if_index, sw_if_index);
  if (!p)
    return VNET_API_ERROR_NO_SUCH_ENTRY;
  classifier_intf_config_t * config = (classifier_intf_config_t *) p[0];

  if (!(config->enabled) && (enable_disable))
    {
      config->enabled = 1;
      rv = 0;
    }
  else if ((config->enabled) && (!enable_disable))
    {
      config->enabled = 0;
      rv = 0;
    }
  if (!rv)
    {
      rv = vnet_feature_enable_disable ("ip4-unicast", "ip4-classifier-acls",
                                        sw_if_index, enable_disable, 0, 0);

      if (!rv)
        rv = ip4_sv_reass_enable_disable_with_refcnt (sw_if_index,
                                                      enable_disable);
      if (!rv)
        vnet_feature_enable_disable ("ip6-unicast", "ip6-classifier-acls",
                                     sw_if_index, enable_disable, 0, 0);
    }

  return rv;
}


static clib_error_t *
classifier_acls_enable_disable_command_fn (vlib_main_t * vm,
                                   unformat_input_t * input,
                                   vlib_cli_command_t * cmd)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 sw_if_index = ~0;
  int enable_disable = 1;

  int rv;

  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "del"))
        enable_disable = 0;
      else if (unformat (input, "%U", unformat_vnet_sw_interface,
                         cmp->vnet_main, &sw_if_index))
        ;
      else
        break;
  }

  if (sw_if_index == ~0)
    return clib_error_return (0, "Please specify a valid interface");

  rv = classifier_acls_enable_disable (cmp, sw_if_index, enable_disable);

  switch(rv)
    {
  case 0:
    break;

  case VNET_API_ERROR_INVALID_SW_IF_INDEX:
    return clib_error_return
      (0, "Invalid interface -  Unsupported interface type");
    break;

  default:
    return clib_error_return (0, "classifier_acls_enable_disable returned %d",
                              rv);
    }
  return 0;
}

/* *INDENT-OFF* */
/*
 * Command to enable or disable classification on the interface. The
 * configuration on the interface stays as is and this command only enables or
 * disables the feature from the interface. It can also help in quick debugging
 * of the packet path with and without this feature
 */
VLIB_CLI_COMMAND (classifier_acls_enable_disable_command, static) =
{
  .path = "classifier-acls enable",
  .short_help = "classifier-acls enable <interface-name> [del]",
  .function = classifier_acls_enable_disable_command_fn,
};
/* *INDENT-ON* */

/*
 * Function to create classifier configuration context based on the given
 * input configuration data. The configuration context is created for every
 * interface that requires classification support
 */
static void
classifier_acls_intf_config_create (u32 sw_if_index, u32 acl_list_id,
                                    u32 policer_id, u32 enable_drop_check,
                                    u16 * tcp_skip_port_list,
                                    u16 * udp_skip_port_list)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 skip_port_count = vec_len (udp_skip_port_list) +
    vec_len (tcp_skip_port_list);
  classifier_intf_config_t * config =
    clib_mem_alloc (sizeof (classifier_intf_config_t));
  config->acl_list_id = acl_list_id;
  config->policer_id = policer_id;
  config->enable_drop_check = enable_drop_check;
  config->skip_port_count = skip_port_count;
  config->enabled = 0;
  config->skip_port_rules = NULL;
  u32 i, j;

  for (i = 0; i < vec_len (udp_skip_port_list); i++)
    {
      classifier_skip_port_t skip_port= {
          .port = udp_skip_port_list[i],
          .protocol = IP_PROTOCOL_UDP,
          .reserved = 0
      };
      vec_add1 (config->skip_port_rules, skip_port);
      u64 skip_port_rule =
        ((u64)sw_if_index << 32) | (config->skip_port_rules[i].as_u32);
      hash_set (cmp->skip_port_rules, skip_port_rule, 1);
    }
  for (j = 0; j < vec_len(tcp_skip_port_list); j++)
    {
      classifier_skip_port_t skip_port= {
          .port = tcp_skip_port_list[i + j],
          .protocol = IP_PROTOCOL_TCP,
          .reserved = 0
      };
      vec_add1 (config->skip_port_rules, skip_port);
      u64 skip_port_rule =
        ((u64)sw_if_index << 32) | (config->skip_port_rules[i + j].as_u32);
      hash_set (cmp->skip_port_rules, skip_port_rule, 1);
    }
  hash_set (cmp->config_by_sw_if_index, sw_if_index, config);
}


/*
 * Function to free classifier configuration context
 */
static void
classifier_acls_intf_config_free (u32 sw_if_index)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  uword * p = hash_get (cmp->config_by_sw_if_index, sw_if_index);
  if (!p)
    return;

  classifier_intf_config_t * config = (classifier_intf_config_t *) p[0];
  classifier_acls_enable_disable (cmp, sw_if_index, 0);

  for (u32 i = 0; i < config->skip_port_count; i++)
    {
      u64 skip_port_rule =
        ((u64)sw_if_index << 32) | config->skip_port_rules[i].as_u32;
      hash_unset (cmp->skip_port_rules, skip_port_rule);
    }
  hash_unset (cmp->config_by_sw_if_index, sw_if_index);
  vec_free (config->skip_port_rules);
  clib_mem_free (config);
}

static clib_error_t *
classifier_acls_set_interface_command_fn (vlib_main_t * vm,
                                          unformat_input_t * input,
                                          vlib_cli_command_t * cmd)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 sw_if_index = ~0;
  u8 is_add = 1;
  u32 acl_list_id = ~0;

  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "%U", unformat_vnet_sw_interface,
                         cmp->vnet_main, &sw_if_index))
        ;
      else if (unformat (input, "acl-list-id %u", &acl_list_id))
        ;
      else if (unformat (input, "del"))
        is_add = 0;
      else
        break;
    }

  if (sw_if_index == ~0)
    return clib_error_return (0, "Please specify a valid interface");

  if (acl_list_id >= CLASSIFIER_MAX_ACL_SETS)
    return clib_error_return (0, "Max supported acl_list_id range is 0 to %u",
                              (CLASSIFIER_MAX_ACL_SETS - 1));

  classifier_acls_intf_config_free (sw_if_index);
  if (is_add)
    classifier_acls_intf_config_create (sw_if_index, acl_list_id, ~0, 0,
                                        NULL, NULL);

  return NULL;
}

/* *INDENT-OFF* */
/*
 * Command to set classification rules identified by the given acl-list-id on
 * the given interface
 */
VLIB_CLI_COMMAND (classifier_acls_set_interface_command, static) =
{
  .path = "classifier-acls set-interface",
  .short_help = "classifier-acls set-interface <interface-name> acl-list-id <acl-list-id> [del]",
  .function = classifier_acls_set_interface_command_fn,
};
/* *INDENT-ON* */

/*
 * Internal utility function to add/delete skip port to the interface
 * configuration
 */
static void
classifier_acls_add_del_skip_port (classifier_acls_main_t * cmp,
                                   classifier_intf_config_t * config,
                                   u32 sw_if_index,
                                   classifier_skip_port_t skip_port, u8 is_add)
{
  u64 skip_port_rule = ((u64)sw_if_index << 32) | skip_port.as_u32;
  uword * p = hash_get (cmp->skip_port_rules, skip_port_rule);
  if (is_add)
    {
      if (!p) //not exist
        {
          vec_add1 (config->skip_port_rules, skip_port);
          hash_set (cmp->skip_port_rules, skip_port_rule, 1);
        }
    }
  else if (p)
    {
      for (i32 i = 0; i < vec_len (config->skip_port_rules); i++)
        {
          if (config->skip_port_rules[i].as_u32 == skip_port.as_u32)
            {
              vec_delete (config->skip_port_rules, 1, i);
              break;
            }
        }
      hash_unset (cmp->skip_port_rules, skip_port_rule);
    }
}

/*
 * Function to update existing interface configuration with additional
 * configuration attributes provided by the user
 */
static clib_error_t *
classifier_acls_set_interface_attr_command_fn (vlib_main_t * vm,
                                               unformat_input_t * input,
                                               vlib_cli_command_t * cmd)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 sw_if_index = ~0;
  u8 is_add = 1;
  u32 enable_drop_check = ~0;
  u32 udp_port = ~0;
  u32 tcp_port = ~0;

  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "%U", unformat_vnet_sw_interface,
                         cmp->vnet_main, &sw_if_index))
        ;
      else if (unformat (input, "drop-check"))
        enable_drop_check = 1;
      else if (unformat (input, "udp-skip-port %u", &udp_port))
        ;
      else if (unformat (input, "tcp-skip-port %u", &tcp_port))
        ;
      else if (unformat (input, "del"))
        {
          is_add = 0;
          if (enable_drop_check == 1)
            enable_drop_check = 0;
        }
      else
        break;
    }

  if (sw_if_index == ~0)
    return clib_error_return (0, "Please specify a valid interface");

  uword *p = hash_get (cmp->config_by_sw_if_index, sw_if_index);
  if (!p)
    return clib_error_return (0, "Config does not exist");

  classifier_intf_config_t * config = (classifier_intf_config_t *) p[0];
  if (enable_drop_check != ~0)
    config->enable_drop_check = enable_drop_check;

  if (udp_port != ~0)
    {
      classifier_skip_port_t skip_port = {
          .protocol = IP_PROTOCOL_UDP,
          .port = clib_host_to_net_u16 (udp_port),
          .reserved = 0
      };
      classifier_acls_add_del_skip_port (cmp, config, sw_if_index, skip_port,
                                         is_add);
    }
  if (tcp_port != ~0)
    {
      classifier_skip_port_t skip_port = {
          .protocol = IP_PROTOCOL_TCP,
          .port = clib_host_to_net_u16 (tcp_port),
          .reserved = 0
      };
      classifier_acls_add_del_skip_port (cmp, config, sw_if_index, skip_port,
                                         is_add);
    }
  return NULL;
}

/* *INDENT-OFF* */
/*
 * Command to set skip port rules to the given interface
 */
VLIB_CLI_COMMAND (classifier_acls_set_interface_attr_command, static) =
{
  .path = "classifier-acls set-interface-attr",
  .short_help = "classifier-acls set-interface-attr <interface-name> drop-check udp-skip-port <port> tcp-skip-port <port> [del]",
  .function = classifier_acls_set_interface_attr_command_fn,
};
/* *INDENT-ON* */


/*
 * Function that sets up ACL plugin context for the ACLs identified using the
 * given unique acl_list_id
 */
static i32
classifier_acls_setup_lc_index (classifier_acls_main_t * cmp, u32 acl_list_id,
                                u32 * acls)
{
  i32 rv = 0;
  if (cmp->acl_lc_index_by_acl_list_id[acl_list_id] == ~0)
    {
      rv = cmp->acl_plugin.get_lookup_context_index (cmp->acl_user_id,
                                                     acl_list_id, 0);
      if (rv < 0)
        clib_warning("Classifier acl lookup setup failed: %d", rv);
      else
        cmp->acl_lc_index_by_acl_list_id[acl_list_id] = rv;
    }
  if (rv >= 0)
    {
      rv = cmp->acl_plugin.set_acl_vec_for_context
        (cmp->acl_lc_index_by_acl_list_id[acl_list_id], acls);
      if (rv < 0)
        clib_warning("Classifier acl list setup failed: %d", rv);
    }
  return rv;
}

/*
 * Function that releases the ACL plugin context corresponding to the
 * acl_list_id
 */
static void
classifier_acls_release_lc_index (classifier_acls_main_t * cmp,
                                  u32 acl_list_id)
{
  u32 lc_index = cmp->acl_lc_index_by_acl_list_id[acl_list_id];
  if (lc_index != ~0)
    {
      cmp->acl_plugin.put_lookup_context_index (lc_index);
      cmp->acl_lc_index_by_acl_list_id[acl_list_id] = ~0;
    }
}


/* *INDENT-OFF* */
/*
 * Function to show all the configuration data on all the enabled interfaces
 */
static clib_error_t *
classifier_acls_show_command_fn (vlib_main_t * vm,
                                 unformat_input_t * input,
                                 vlib_cli_command_t * cmd)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  u32 sw_if_index;
  classifier_intf_config_t *config;

  hash_foreach (sw_if_index, config, cmp->config_by_sw_if_index, {

        vlib_cli_output (vm, "sw_if_index: %u\n", sw_if_index);
        vlib_cli_output (vm, "---------------\n");
        if (config->acl_list_id != ~0)
          vlib_cli_output (vm, "acl_list_id %u\n", config->acl_list_id);

        if (config->policer_id != ~0)
          vlib_cli_output (vm, "policer_id %u\n", config->enable_drop_check);

        if (config->enable_drop_check != 0)
          vlib_cli_output (vm, "drop_check enabled\n");

      for (i32 i = 0; i < vec_len (config->skip_port_rules); i++)
        {
           vlib_cli_output (vm, "skip port %s %u\n",
                            (config->skip_port_rules[i].protocol == IP_PROTOCOL_UDP) ? "udp" : "tcp",
                             clib_net_to_host_u16 (config->skip_port_rules[i].port));
        }
        vlib_cli_output (vm, "\n\n");
    });
  return NULL;
}

/*
 * Command to show the config of the classification feature.
 */
VLIB_CLI_COMMAND (classifier_acls_show_command, static) =
{
  .path = "show classifier-acls",
  .short_help = "show classifier-acls",
  .function = classifier_acls_show_command_fn,
};
/* *INDENT-ON* */


/* API message handler */
static void vl_api_classifier_acls_enable_disable_t_handler
(vl_api_classifier_acls_enable_disable_t * mp)
{
  vl_api_classifier_acls_enable_disable_reply_t * rmp;
  classifier_acls_main_t * cmp = &classifier_acls_main;
  int rv;

  rv = classifier_acls_enable_disable (cmp,
                                       clib_net_to_host_u32(mp->sw_if_index),
                                       (int) (mp->enable_disable));

  REPLY_MACRO(VL_API_CLASSIFIER_ACLS_ENABLE_DISABLE_REPLY);
}

static void
  vl_api_classifier_acls_set_interface_t_handler
  (vl_api_classifier_acls_set_interface_t * mp)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  vl_api_classifier_acls_set_interface_reply_t *rmp;
  vnet_interface_main_t *im = &cmp->vnet_main->interface_main;
  u32 sw_if_index = clib_net_to_host_u32 (mp->sw_if_index);
  u32 acl_list_id = clib_net_to_host_u32 (mp->acl_list_id);
  u16 skip_port_count = clib_net_to_host_u16 (mp->skip_port_count);
  u16 tcp_skip_port_count = clib_net_to_host_u16 (mp->tcp_skip_port_count);
  int rv = 0;

  if (acl_list_id >= CLASSIFIER_MAX_ACL_SETS)
    {
      rv = VNET_API_ERROR_NO_SUCH_ENTRY;
      goto end_return;
    }

  if (pool_is_free_index (im->sw_interfaces, sw_if_index))
    {
      rv = VNET_API_ERROR_INVALID_SW_IF_INDEX;
      goto end_return;
    }

  classifier_acls_intf_config_free (sw_if_index);
  if (!mp->is_add)
    goto end_return;
  u16 * tcp_skip_port_list = NULL;
  u16 * udp_skip_port_list = NULL;
  for (u32 i = 0; i < skip_port_count; i++)
    {
      if (i < tcp_skip_port_count)
        vec_add1 (tcp_skip_port_list, mp->skip_port_list[i]);
      else
        vec_add1 (udp_skip_port_list, mp->skip_port_list[i]);
    }

  classifier_acls_intf_config_create (sw_if_index, acl_list_id, ~0,
                                      mp->enable_drop_check,
                                      tcp_skip_port_list,
                                      udp_skip_port_list);

  vec_free (tcp_skip_port_list);
  vec_free (udp_skip_port_list);

end_return:
  REPLY_MACRO (VL_API_CLASSIFIER_ACLS_SET_INTERFACE_REPLY);
}

static void
  vl_api_classifier_acls_set_interface_policer_t_handler
  (vl_api_classifier_acls_set_interface_policer_t * mp)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  vl_api_classifier_acls_set_interface_policer_reply_t *rmp;
  vnet_interface_main_t *im = &cmp->vnet_main->interface_main;
  u32 sw_if_index = clib_net_to_host_u32 (mp->sw_if_index);
  int rv = 0;
  u8 * name = NULL;
  int policer_id;

  if (pool_is_free_index (im->sw_interfaces, sw_if_index))
    {
      rv = VNET_API_ERROR_INVALID_SW_IF_INDEX;
      goto end_return;
    }
  name = format (0, "%s", mp->name);
  vec_terminate_c_string (name);
  policer_id = get_policer_index_by_name (name);
  if (policer_id < 0)
    {
      rv = VNET_API_ERROR_NO_SUCH_ENTRY;
      goto end_return;
    }

  uword *p = hash_get (cmp->config_by_sw_if_index, sw_if_index);
  if (!p)
    {
      rv = VNET_API_ERROR_NO_SUCH_ENTRY;
      goto end_return;
    }
  classifier_intf_config_t * config = (classifier_intf_config_t *) p[0];
  if (mp->is_add)
    config->policer_id = policer_id;
  else
    config->policer_id = ~0;

end_return:
  vec_free (name);
  REPLY_MACRO (VL_API_CLASSIFIER_ACLS_SET_INTERFACE_POLICER_REPLY);
}


static void
  vl_api_classifier_acls_set_acls_t_handler
  (vl_api_classifier_acls_set_acls_t * mp)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  vl_api_classifier_acls_set_acls_reply_t *rmp;
  u32 acl_count = clib_net_to_host_u32 (mp->count);
  u32 acl_list_id = clib_net_to_host_u32 (mp->acl_list_id);
  int rv = 0;

  if (acl_list_id >= CLASSIFIER_MAX_ACL_SETS)
    {
      rv = VNET_API_ERROR_NO_SUCH_ENTRY;
      goto end_return;
    }

  if (acl_count)
    {
      uword *seen_acl_bitmap = 0;
      u32 * acls = NULL;
      u32 acl_index;
      for (u32 i = 0; i < acl_count; i++)
        {
          acl_index = clib_net_to_host_u32 (mp->acls[i]);
          /* Check if ACLs exist */
          if (!cmp->acl_plugin.acl_exists (acl_index))
            {
              rv = VNET_API_ERROR_NO_SUCH_ENTRY;
              break;
            }
          /* Check if any ACL is being applied twice */
          if (clib_bitmap_get (seen_acl_bitmap, acl_index))
            {
              rv = VNET_API_ERROR_ENTRY_ALREADY_EXISTS;
              break;
            }
          seen_acl_bitmap = clib_bitmap_set (seen_acl_bitmap, acl_index, 1);
          vec_add1 (acls, acl_index);
        }
      if (!rv)
        rv = classifier_acls_setup_lc_index (cmp, acl_list_id, acls);
      clib_bitmap_free (seen_acl_bitmap);
      vec_free (acls);
    }
  else
    classifier_acls_release_lc_index (cmp, acl_list_id);

end_return:
  REPLY_MACRO (VL_API_CLASSIFIER_ACLS_SET_ACLS_REPLY);
}

/* API definitions */
#include <classifier_acls/classifier_acls.api.c>

static clib_error_t * classifier_acls_init (vlib_main_t * vm)
{
  classifier_acls_main_t * cmp = &classifier_acls_main;
  clib_error_t * error = 0;

  cmp->vlib_main = vm;
  cmp->vnet_main = vnet_get_main();
  cmp->config_by_sw_if_index = 0;
  for (int i = 0; i < CLASSIFIER_MAX_ACL_SETS; i++)
    cmp->acl_lc_index_by_acl_list_id[i] = ~0;

  /* Add our API messages to the global name_crc hash table */
  cmp->msg_id_base = setup_message_id_table ();

  clib_error_t *rv = acl_plugin_exports_init (&cmp->acl_plugin);
  if (rv)
    return (rv);
  cmp->acl_user_id = cmp->acl_plugin.register_user_module
    ("Classifier ACLs plugin", "acl_list_id", NULL);

  return error;
}

static clib_error_t *
classifier_acls_sw_interface_add_del (vnet_main_t * vnm, u32 sw_if_index,
				      u32 is_add)
{
  if (!is_add)
    classifier_acls_intf_config_free (sw_if_index);
  return 0;
}

VNET_SW_INTERFACE_ADD_DEL_FUNCTION (classifier_acls_sw_interface_add_del);

VLIB_INIT_FUNCTION (classifier_acls_init);

/* *INDENT-OFF* */
VNET_FEATURE_INIT (ip4_classifier_acls, static) =
{
  .arc_name = "ip4-unicast",
  .node_name = "ip4-classifier-acls",
  .runs_after = VNET_FEATURES ("acl-plugin-in-ip4-fa", "ip4-sv-reassembly-feature"),
  .runs_before = VNET_FEATURES ("abf-input-ip4","fwabf-input-ip4"),
};

VNET_FEATURE_INIT (ip6_classifier_acls, static) =
{
  .arc_name = "ip6-unicast",
  .node_name = "ip6-classifier-acls",
  .runs_after = VNET_FEATURES ("acl-plugin-in-ip6-fa", "ip6-sv-reassembly-feature"),
  .runs_before = VNET_FEATURES ("abf-input-ip6","fwabf-input-ip6"),
};


VLIB_PLUGIN_REGISTER () =
{
  .version = VPP_BUILD_VER,
  .description = "classifier_acls plugin - ACL based traffic classifier",
};
/* *INDENT-ON* */


__clib_export u32
classifier_acls_classify_packet_api (vlib_buffer_t *b, u32 sw_if_index,
				     u8 is_ip6, u32 *out_acl_index,
                                     u32 *out_acl_rule_index)
{
  return classifier_acls_classify_packet (b, sw_if_index, is_ip6,
                                          out_acl_index, out_acl_rule_index);
}

/*
 * fd.io coding-style-patch-verification: ON
 *
 * Local Variables:
 * eval: (c-set-style "gnu")
 * End:
 */
