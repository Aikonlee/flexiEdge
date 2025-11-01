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

#include <vnet/fib/fib_node.h>
#include <vnet/fib/fib_node_list.h>
#include <vnet/fib/fib_table.h>
#include <vnet/mfib/mfib_table.h>

/*
 * The per-type vector of virtual function tables
 */
static fib_node_vft_t *fn_vfts;

/**
 * The last registered new type
 */
static fib_node_type_t last_new_type = FIB_NODE_TYPE_LAST;

/*
 * the node type names
 */
static const char *fn_type_names[] = FIB_NODE_TYPES;

const char*
fib_node_type_get_name (fib_node_type_t type)
{
    if (type < FIB_NODE_TYPE_LAST)
	return (fn_type_names[type]);
    else
    {
	if (NULL != fn_vfts[type].fnv_format)
	{
	    return ("fixme");
	}
	else
	{
	    return ("unknown");
	}
    }
}

/**
 * fib_node_register_type
 *
 * Register the function table for a given type
 */
void
fib_node_register_type (fib_node_type_t type,
			const fib_node_vft_t *vft)
{
    /*
     * assert that one only registration is made per-node type
     */
    if (vec_len(fn_vfts) > type)
	ASSERT(NULL == fn_vfts[type].fnv_get);

    /*
     * Assert that we are getting each of the required functions
     */
    ASSERT(NULL != vft->fnv_get);
    ASSERT(NULL != vft->fnv_last_lock);

    vec_validate(fn_vfts, type);
    fn_vfts[type] = *vft;
}

fib_node_type_t
fib_node_register_new_type (const fib_node_vft_t *vft)
{
    fib_node_type_t new_type;

    new_type = ++last_new_type;

    fib_node_register_type(new_type, vft);

    return (new_type);
}   

static u8*
fib_node_format (fib_node_ptr_t *fnp, u8*s)
{
    return (format(s, "{%s:%d}", fn_type_names[fnp->fnp_type], fnp->fnp_index)); 
}

u32
fib_node_child_add (fib_node_type_t parent_type,
                    fib_node_index_t parent_index,
                    fib_node_type_t type,
		    fib_node_index_t index)
{
    fib_node_t *parent;

    parent = fn_vfts[parent_type].fnv_get(parent_index);

    /*
     * return the index of the sibling in the child list
     */
    fib_node_lock(parent);

    if (FIB_NODE_INDEX_INVALID == parent->fn_children)
    {
        parent->fn_children = fib_node_list_create();
    }   

    return (fib_node_list_push_front(parent->fn_children,
                                     0, type,
                                     index));
}

void
fib_node_child_remove (fib_node_type_t parent_type,
                       fib_node_index_t parent_index,
                       fib_node_index_t sibling_index)
{
    fib_node_t *parent;

    parent = fn_vfts[parent_type].fnv_get(parent_index);

#ifdef FLEXIWAN_FIX
    /* For some reason we might get here with empty parent->fn_children list.
       As after long 4 years I am still not familiar with VPP enough,
       I can't track down the real reason for this abnormal situation,
       so I just block the crash here :/
	   It looks safe, as the "sibling_index" is not used anymore after this function returns.
	   See fib_entry_src_action_deactivate() in fib_entry_src.c:1154.

            libc.so.6!__GI_raise(int sig) (\build\glibc-SzIz7B\glibc-2.31\sysdeps\unix\sysv\linux\raise.c:50)
            libc.so.6!__GI_abort() (\build\glibc-SzIz7B\glibc-2.31\stdlib\abort.c:79)
            os_exit(int code) (\opt\build\flexirouter.git\vpp\src\vpp\vnet\main.c:433)
            libvlib.so.21.01.02.03.14!unix_signal_handler(int signum, siginfo_t * si, ucontext_t * uc) (\opt\build\flexirouter.git\vpp\src\vlib\unix\main.c:187)
            libpthread.so.0!<signal handler called> (Unknown Source:0)
            libvnet.so.21.01.02.03.14!fib_node_list_extract(fib_node_list_head_t * head, fib_node_list_elt_t * elt, fib_node_list_elt_t * elt) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_node_list.c:212)
            libvnet.so.21.01.02.03.14!fib_node_list_remove(fib_node_list_t list, u32 sibling) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_node_list.c:243)
            libvnet.so.21.01.02.03.14!fib_node_child_remove(fib_node_type_t parent_type, fib_node_index_t parent_index, fib_node_index_t sibling_index) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_node.c:131)
            libvnet.so.21.01.02.03.14!fib_path_list_child_remove(fib_node_index_t path_list_index, u32 si) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_path_list.c:1352)
            libvnet.so.21.01.02.03.14!fib_entry_src_action_deactivate(fib_entry_t * fib_entry, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_entry_src.c:1154)
            libvnet.so.21.01.02.03.14!fib_entry_src_action_remove(fib_entry_t * fib_entry, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_entry_src.c:1450)
            libvnet.so.21.01.02.03.14!fib_entry_src_action_remove_or_update_inherit(fib_entry_t * fib_entry, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_entry_src.c:1419)
            libvnet.so.21.01.02.03.14!fib_entry_special_remove(fib_node_index_t fib_entry_index, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_entry.c:1117)
            libvnet.so.21.01.02.03.14!fib_entry_delete(fib_node_index_t fib_entry_index, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_entry.c:1219)
            libvnet.so.21.01.02.03.14!fib_table_entry_delete_i(u32 fib_index, fib_node_index_t fib_entry_index, const fib_prefix_t * prefix, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_table.c:866)
            libvnet.so.21.01.02.03.14!fib_table_entry_delete(u32 fib_index, const fib_prefix_t * prefix, fib_source_t source) (\opt\build\flexirouter.git\vpp\src\vnet\fib\fib_table.c:914)
            libvnet.so.21.01.02.03.14!ip4_del_interface_routes(ip4_main_t * im, u32 address_length, u32 fib_index, u32 sw_if_index) (\opt\build\flexirouter.git\vpp\src\vnet\ip\ip4_forward.c:603)
            libvnet.so.21.01.02.03.14!ip4_sw_interface_admin_up_down(vnet_main_t * vnm, u32 sw_if_index, u32 flags) (\opt\build\flexirouter.git\vpp\src\vnet\ip\ip4_forward.c:912)
            libvnet.so.21.01.02.03.14!call_elf_section_interface_callbacks(_vnet_interface_function_list_elt_t ** elts, u32 flags, u32 if_index, vnet_main_t * vnm) (\opt\build\flexirouter.git\vpp\src\vnet\interface.c:258)
            libvnet.so.21.01.02.03.14!vnet_sw_interface_set_flags_helper(vnet_main_t * vnm, u32 sw_if_index, vnet_sw_interface_flags_t flags, vnet_interface_helper_flags_t helper_flags) (\opt\build\flexirouter.git\vpp\src\vnet\interface.c:435)
    */
    if (FIB_NODE_INDEX_INVALID == parent->fn_children) {
        fib_node_unlock(parent);
        return;
    }
#endif /*#ifdef FLEXIWAN_FIX*/

    fib_node_list_remove(parent->fn_children, sibling_index);

    if (0 == fib_node_list_get_size(parent->fn_children))
    {
        fib_node_list_destroy(&parent->fn_children);
    }

    fib_node_unlock(parent);
}

u32
fib_node_get_n_children (fib_node_type_t parent_type,
                         fib_node_index_t parent_index)
{
    fib_node_t *parent;

    parent = fn_vfts[parent_type].fnv_get(parent_index);

    return (fib_node_list_get_size(parent->fn_children));
}


fib_node_back_walk_rc_t
fib_node_back_walk_one (fib_node_ptr_t *ptr,
                        fib_node_back_walk_ctx_t *ctx)
{
    fib_node_t *node;

    node = fn_vfts[ptr->fnp_type].fnv_get(ptr->fnp_index);

    return (fn_vfts[ptr->fnp_type].fnv_back_walk(node, ctx));
}

static walk_rc_t
fib_node_ptr_format_one_child (fib_node_ptr_t *ptr,
			       void *arg)
{
    u8 **s = (u8**) arg;

    *s = fib_node_format(ptr, *s);

    return (WALK_CONTINUE);
}

u8*
fib_node_children_format (fib_node_list_t list,
			  u8 *s)
{
    fib_node_list_walk(list, fib_node_ptr_format_one_child, (void*)&s);

    return (s);
}

void
fib_node_init (fib_node_t *node,
	       fib_node_type_t type)
{
    /**
     * The node's type. used to retrieve the VFT.
     */
    node->fn_type = type;
    node->fn_locks = 0;
    node->fn_children = FIB_NODE_INDEX_INVALID;
}

void
fib_node_deinit (fib_node_t *node)
{
    fib_node_list_destroy(&node->fn_children);
}

void
fib_node_lock (fib_node_t *node)
{
    node->fn_locks++;
}

void
fib_node_unlock (fib_node_t *node)
{
    node->fn_locks--;

    if (0 == node->fn_locks)
    {
	fn_vfts[node->fn_type].fnv_last_lock(node);
    }
}

void
fib_show_memory_usage (const char *name,
		       u32 in_use_elts,
		       u32 allocd_elts,
		       size_t size_elt)
{
    vlib_cli_output (vlib_get_main(), "%=30s %=5d %=8d/%=9d   %d/%d ",
		     name, size_elt,
		     in_use_elts, allocd_elts,
		     in_use_elts*size_elt, allocd_elts*size_elt);
}

static clib_error_t *
fib_memory_show (vlib_main_t * vm,
		 unformat_input_t * input,
		 vlib_cli_command_t * cmd)
{
    fib_node_vft_t *vft;

    vlib_cli_output (vm, "FIB memory");
    vlib_cli_output (vm, "  Tables:");
    vlib_cli_output (vm, "%=30s %=6s %=12s", "SAFI", "Number", "Bytes");
    vlib_cli_output (vm, "%U", format_fib_table_memory);
    vlib_cli_output (vm, "%U", format_mfib_table_memory);
    vlib_cli_output (vm, "  Nodes:");
    vlib_cli_output (vm, "%=30s %=5s %=8s/%=9s   totals",
		     "Name","Size", "in-use", "allocated");

    vec_foreach(vft, fn_vfts)
    {
	if (NULL != vft->fnv_mem_show)
	    vft->fnv_mem_show();
    }

    fib_node_list_memory_show();

    return (NULL);
}

/* *INDENT-OFF* */
/*?
 * The '<em>sh fib memory </em>' command displays the memory usage for each
 * FIB object type.
 *
 * @cliexpar
 * @cliexstart{show fib memory}
 *FIB memory
 * Tables:
 *            SAFI              Number   Bytes
 *        IPv4 unicast             2    673066
 *        IPv6 unicast             2    1054608
 *            MPLS                 1    4194312
 *       IPv4 multicast            2     2322
 *       IPv6 multicast            2      ???
 * Nodes:
 *            Name               Size  in-use /allocated   totals
 *            Entry               96     20   /    20      1920/1920
 *        Entry Source            32      0   /    0       0/0
 *    Entry Path-Extensions       60      0   /    0       0/0
 *       multicast-Entry         192     12   /    12      2304/2304
 *          Path-list             40     28   /    28      1120/1120
 *          uRPF-list             16     20   /    20      320/320
 *            Path                72     28   /    28      2016/2016
 *     Node-list elements         20     28   /    28      560/560
 *       Node-list heads          8      30   /    30      240/240
 * @cliexend
?*/
VLIB_CLI_COMMAND (show_fib_memory, static) = {
    .path = "show fib memory",
    .function = fib_memory_show,
    .short_help = "show fib memory",
};
/* *INDENT-ON* */
