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
 *  Copyright (C) 2019 flexiWAN Ltd.
 *  List of fixes made for FlexiWAN (denoted by FLEXIWAN_FIX flag):
 *   - add missing functionality:
 *      1. Handle REPLACE netlink messages (RTM_NEWROUTE with NLM_F_REPLACE flag)
 *      2. Add support in RTA_MULTIPATH attribute of netlink messages.
 *   - fix hashing logic: use 'dst' as key for hash. This is to prevent
 *     duplicated entries in VPP FIB and out of think between VPP FIB and kernel.
 *   - fix handling RTM_NEWNEIGH messages to prevent duplicated entries in VPP
 *   - when link goes down, routes are deleted on linux side, we need to delete them on VPP side too
 */

#include <librtnl/netns.h>

#include <vnet/dpo/dpo.h>     /* bring INDEX_INVALID */
#include <vnet/ip/format.h>
#include <vnet/ip/ip.h>
#include <vnet/ip/ip_types_api.h>
#include <vnet/ethernet/ethernet.h>

#include <stddef.h>

/* Enable some RTA values debug */
//#define RTNL_CHECK

#define is_nonzero(x)                           \
  ({                                            \
    u8 __is_zero_zero[sizeof(x)] = {};          \
    memcmp(__is_zero_zero, &x, sizeof(x));      \
  })

typedef struct {
  u8 type;      //Attribute identifier
  u8 unique;    //Part of the values uniquely identifying an entry
  u16 offset;   //Offset where stored in struct
  u16 size;     //Length of the attribute
} rtnl_mapping_t;

#define ns_foreach_ifla                         \
  _(IFLA_ADDRESS, hwaddr)                       \
  _(IFLA_BROADCAST, broadcast)                  \
  _(IFLA_IFNAME, ifname)                        \
  _(IFLA_MASTER, master)                        \
  _(IFLA_MTU, mtu)                              \
  _(IFLA_QDISC, qdisc)

static rtnl_mapping_t ns_ifmap[] = {
#define _(t, e)                                 \
  {                                             \
    .type = t,                                  \
    .offset = offsetof(ns_link_t, e),           \
    .size = sizeof(((ns_link_t*)0)->e)          \
  },
  ns_foreach_ifla
#undef _
  { .type = 0 }
};

u8 *format_ns_link (u8 *s, va_list *args)
{
  ns_link_t *l = va_arg(*args, ns_link_t *);
  s = format(s, "%s index %u", l->ifname, l->ifi.ifi_index);
  return s;
}

static u8 rtnl_debug_enabled = 0;

static inline int
rtnl_debug_is_enabled (void)
{
  return rtnl_debug_enabled;
}

void rtnl_enable_debug(int enable)
{
  rtnl_debug_enabled = enable;
}

#ifdef FLEXIWAN_FIX
/*
 * The 'ns_routemap' list below 0/1 to mark key for hash, where librtnl stores
 * routes added by kernel.
 * We use 'dst' only as a key, as it the only intersection between key for kernel
 * routing rules and key for FIB entries. Kernel uses 'dst' and 'metric' to
 * identify routing rules (for example, when it sends RTM_NEWROUTE netlink
 * message with NLM_F_REPLACE flag). FIB doesn't support metric (VPP 19.01).
 * We will ignore RTM_NEWROUTE, if route for same 'dst' exists in hash.
 * We will delete route from hash on the first RTM_DELROUTE message with
 * matching 'dst'. That might cause out-of-synch of VPP FIB and kernel for matter
 * of metrics, but 'dst' should be OK.
 */
#endif

#define ns_foreach_rta                          \
  _(RTA_DST, dst, 1)                            \
  _(RTA_SRC, src, 0)                            \
  _(RTA_VIA, via, 0)                            \
  _(RTA_GATEWAY, gateway, 0)                    \
  _(RTA_IIF, iif, 0)                            \
  _(RTA_OIF, oif, 0)                            \
  _(RTA_PREFSRC, prefsrc, 0)                    \
  _(RTA_TABLE, table, 0)                        \
  _(RTA_PRIORITY, priority, 1)                  \
  _(RTA_CACHEINFO, cacheinfo, 0)                \
  _(RTA_ENCAP, encap, 1)                        \
  _(RTA_MULTIPATH, multipath, 0)

static rtnl_mapping_t ns_routemap[] = {
#define _(t, e, u)                              \
  {                                             \
    .type = t, .unique = u,                     \
    .offset = offsetof(ns_route_t, e),          \
    .size = sizeof(((ns_route_t*)0)->e)         \
  },
  ns_foreach_rta
#undef _
  { .type = 0 }
};
#undef ns_foreach_rta
static rtnl_mapping_t* ns_routemap_kernel = ns_routemap;

#define ns_foreach_rta                          \
  _(RTA_DST, dst, 1)                            \
  _(RTA_SRC, src, 0)                            \
  _(RTA_VIA, via, 0)                            \
  _(RTA_GATEWAY, gateway, 1)                    \
  _(RTA_IIF, iif, 0)                            \
  _(RTA_OIF, oif, 0)                            \
  _(RTA_PREFSRC, prefsrc, 0)                    \
  _(RTA_TABLE, table, 0)                        \
  _(RTA_PRIORITY, priority, 0)                  \
  _(RTA_CACHEINFO, cacheinfo, 0)                \
  _(RTA_ENCAP, encap, 1)                        \
  _(RTA_MULTIPATH, multipath, 0)

static rtnl_mapping_t ns_routemap_fib[] = {
#define _(t, e, u)                              \
  {                                             \
    .type = t, .unique = u,                     \
    .offset = offsetof(ns_route_t, e),          \
    .size = sizeof(((ns_route_t*)0)->e)         \
  },
  ns_foreach_rta
#undef _
  { .type = 0 }
};
#undef ns_foreach_rta

u8 *format_ns_route (u8 *s, va_list *args)
{
  ns_route_t *r = va_arg(*args, ns_route_t *);
  void *format_ip = r->rtm.rtm_family == AF_INET ? format_ip4_address : format_ip6_address;
  s = format(s, "%U/%d", format_ip, r->dst, r->rtm.rtm_dst_len);
  if (r->rtm.rtm_src_len)
    s = format(s, " from %U/%d", format_ip, r->src, r->rtm.rtm_src_len);
  if (is_nonzero(r->gateway))
    s = format(s, " via %U", format_ip, r->gateway);
  if (r->iif)
    s = format(s, " iif %d", r->iif);
  if (r->oif)
    s = format(s, " oif %d", r->oif);
  if (is_nonzero(r->prefsrc))
    s = format(s, " src %U", format_ip, r->prefsrc);
  if (r->table)
    s = format(s, " table %d", r->table);
  if (r->priority)
    s = format(s, " priority %u", r->priority);
  if (is_nonzero(r->encap)) {
    s = format(s, " encap");
    for (u32 i=0; i<MPLS_STACK_DEPTH; i++)
      s = format(s, " %u", r->encap[i]);
  }
  if (r->ns != NULL && r->fri != INDEX_INVALID) {  /*r->ns can be NULL if called for NETLINK message (format_rtnl_msg, hdr)*/
    ns_fib_reference_t* fr = pool_elt_at_index(r->ns->fib_refs, r->fri);
    s = format(s, " fib_ref_counter %d (idx=%u)", fr->ref_counter, r->fri);
  }
  return s;
}

#define ns_foreach_ifaddr                       \
  _(IFA_ADDRESS, addr, 1)                       \
  _(IFA_LOCAL, local, 1)                        \
  _(IFA_LABEL, label, 0)                        \
  _(IFA_BROADCAST, broadcast, 0)                \
  _(IFA_ANYCAST, anycast, 0)                    \
  _(IFA_CACHEINFO, cacheinfo, 0)

static rtnl_mapping_t ns_addrmap[] = {
#define _(t, e, u)                              \
  {                                             \
    .type = t, .unique = u,                     \
    .offset = offsetof(ns_addr_t, e),           \
    .size = sizeof(((ns_addr_t*)0)->e)          \
  },
  ns_foreach_ifaddr
#undef _
  { .type = 0 }
};

u8 *format_ns_addr (u8 *s, va_list *args)
{
  ns_addr_t *a = va_arg(*args, ns_addr_t *);
  void *format_ip = a->ifaddr.ifa_family == AF_INET ? format_ip4_address : format_ip6_address;
  s = format(s, "%U/%d", format_ip, a->addr, a->ifaddr.ifa_prefixlen);
  if (is_nonzero(a->label))
    s = format(s, " dev %s", a->label);
  if (is_nonzero(a->broadcast))
    s = format(s, " broadcast %U", format_ip, a->broadcast);
  if (is_nonzero(a->anycast))
    s = format(s, " anycast %U", format_ip, a->anycast);
  if (is_nonzero(a->local))
    s = format(s, " local %U", format_ip, a->local);
  return s;
}

#ifndef NDA_RTA
#define NDA_RTA(r)  ((struct rtattr*)(((char*)(r)) + NLMSG_ALIGN(sizeof(struct ndmsg))))
#define NDA_PAYLOAD(n) NLMSG_PAYLOAD(n,sizeof(struct ndmsg))
#endif

#define ns_foreach_neigh                        \
  _(NDA_DST, dst, 1)                            \
  _(NDA_LLADDR, lladdr, 0)                      \
  _(NDA_PROBES, probes, 0)                      \
  _(NDA_CACHEINFO, cacheinfo, 0)

static rtnl_mapping_t ns_neighmap[] = {
#define _(t, e, u)                              \
  {                                             \
    .type = t, .unique = u,                     \
    .offset = offsetof(ns_neigh_t, e),          \
    .size = sizeof(((ns_neigh_t*)0)->e)         \
  },
  ns_foreach_neigh
#undef _
  { .type = 0 }
};

u8 *format_ns_neigh (u8 *s, va_list *args)
{
  ns_neigh_t *n = va_arg(*args, ns_neigh_t *);
  void *format_ip = n->nd.ndm_family == AF_INET ? format_ip4_address : format_ip6_address;
  s = format(s, "%U", format_ip, n->dst);
  if (is_nonzero(n->lladdr))
    s = format(s, " lladdr %U", format_ethernet_address, n->lladdr);
  if (n->probes)
    s = format(s, " probes %d", n->probes);
  return s;
}

typedef struct {
  void (*notify)(void *obj, netns_type_t type, u32 flags, uword opaque);
  uword opaque;
  u32 netns_index;
} netns_handle_t;

typedef struct {
  netns_t netns;
  u32 rtnl_handle;
  u32 subscriber_count;
} netns_p;

typedef struct {
  netns_p *netnss;
  netns_handle_t *handles;
} netns_main_t;

netns_main_t netns_main;

static int
rtnl_parse_rtattr(struct rtattr *db[], size_t max,
                  struct rtattr *rta, size_t len) {
  for(; RTA_OK(rta, len); rta = RTA_NEXT(rta, len)) {
    if (rta->rta_type <= max)
      db[rta->rta_type] = rta;
#ifdef RTNL_CHECK
    else
      clib_warning("RTA type too high: %d", rta->rta_type);
#endif
  }

  if(len) {
    clib_warning("rattr lenght mistmatch %d %d len",
                 (int) len, (int) rta->rta_len);
    return -1;
  }
  return 0;
}

/*
 * Debug function to display when
 * we receive an RTA that I forgot in
 * the mapping table (there are so many of them).
 */
#ifdef RTNL_CHECK
static void
rtnl_entry_check(struct rtattr *rtas[],
                 size_t rta_len,
                 rtnl_mapping_t map[],
                 char *logstr)
{
  int i;
  for (i=0; i<rta_len; i++) {
    if (!rtas[i])
      continue;

    rtnl_mapping_t *m = map;
    for (m = map; m->type; m++) {
      if (m->type == rtas[i]->rta_type)
        break;
    }
    if (!m->type)
      clib_warning("Unknown RTA type %d (%s)", rtas[i]->rta_type, logstr);
  }
}
#endif

/*
 * Check if the provided entry matches the parsed and unique rtas
 */
static int
rtnl_entry_match(void *entry,
                 struct rtattr *rtas[],
                 rtnl_mapping_t map[])
{
  u8 zero[1024] = {};
  for ( ;map->type != 0; map++) {
    struct rtattr *rta = rtas[map->type];
    size_t rta_len = rta?RTA_PAYLOAD(rta):0;
    if (!map->unique)
      continue;

    if (map->type == RTA_MULTIPATH && rta) {
        multipath_t *multipath = (multipath_t*)(entry + map->offset);

        if (memcmp(RTA_DATA(rta), multipath->nhops, rta_len))
          return 0;
        else
          return 1;
      }

    if (rta && RTA_PAYLOAD(rta) > map->size) {
      clib_warning("rta (type=%d len=%d) too long (max %d)",
                   rta->rta_type, rta->rta_len, map->size);
      return -1;
    }

    if ((rta && memcmp(RTA_DATA(rta), entry + map->offset, rta_len)) ||
        memcmp(entry + map->offset + rta_len, zero, map->size - rta_len)) {
      return 0;
    }
  }
  return 1;
}

static int
rtnl_entry_set(void *entry,
               struct rtattr *rtas[],
               rtnl_mapping_t map[],
               int init)
{
  for (; map->type != 0; map++) {

    struct rtattr *rta = rtas[map->type];

    if(map->type == RTA_ENCAP && rta) {
      /*Data of RTA_ENCAP is a pointer to rta attributes for MPLS*/
      rta = (struct rtattr*)RTA_DATA(rta);
      if (RTA_PAYLOAD(rta) > map->size) {
        clib_warning("rta (type=%d len=%d) too long (max %d)", rta->rta_type, rta->rta_len, map->size);
        return -1;
      }
      memcpy(entry + map->offset, RTA_DATA(rta), map->size);
      memset(entry + map->offset + map->size, 0, 0);
    }
    else if (map->type == RTA_MULTIPATH && rta) {
        multipath_t *multipath = (multipath_t*)(entry + map->offset);
        if (RTA_PAYLOAD(rta) > sizeof(multipath->nhops)) {
          clib_warning("rta (type=%d len=%d) too long (max %d)", rta->rta_type, rta->rta_len, map->size);
          return -1;
        }
        memcpy(multipath->nhops, RTA_DATA(rta), RTA_PAYLOAD(rta));
        multipath->length = RTA_PAYLOAD(rta);
      }
    else if (rta) {
      if (RTA_PAYLOAD(rta) > map->size) {
        clib_warning("rta (type=%d len=%d) too long (max %d)", rta->rta_type, rta->rta_len, map->size);
        return -1;
      }
      memcpy(entry + map->offset, RTA_DATA(rta), RTA_PAYLOAD(rta));
      memset(entry + map->offset + RTA_PAYLOAD(rta), 0, map->size - RTA_PAYLOAD(rta));
    } else if (init) {
      memset(entry + map->offset, 0, map->size);
    }
  }
  return 0;
}

void
netns_notify(netns_p *ns, void *obj, netns_type_t type, u32 flags)
{
  netns_main_t *nm = &netns_main;
  netns_handle_t *h;
  pool_foreach(h, nm->handles) {
      if (h->netns_index == (ns - nm->netnss) &&  h->notify)
        h->notify(obj, type, flags, h->opaque);
    };
}

static_always_inline int
mask_match(void *a, void *b, void *mask, size_t len)
{
  u8 *va = (u8 *) a;
  u8 *vb = (u8 *) b;
  u8 *vm = (u8 *) mask;
  while (len--) {
    if ((va[len] ^ vb[len]) & vm[len])
      return 0;
  }
  return 1;
}

static ns_link_t *
ns_get_link(netns_p *ns, struct ifinfomsg *ifi, struct rtattr *rtas[])
{
  ns_link_t *link;
  pool_foreach(link, ns->netns.links) {
      if(ifi->ifi_index == link->ifi.ifi_index)
        return link;
    };
  return NULL;
}

static void ns_del_route(netns_p *ns, ns_route_t *route);

static int
ns_rcv_link(netns_p *ns, struct nlmsghdr *hdr)
{
  ns_link_t *link;
  struct ifinfomsg *ifi;
  struct rtattr *rtas[IFLA_MAX + 1] = {};
  size_t datalen = hdr->nlmsg_len - NLMSG_ALIGN(sizeof(*hdr));

  if(datalen < sizeof(*ifi))
    return -1;

  ifi = NLMSG_DATA(hdr);
  if((datalen > NLMSG_ALIGN(sizeof(*ifi))) &&
     rtnl_parse_rtattr(rtas, IFLA_MAX, IFLA_RTA(ifi),
                       IFLA_PAYLOAD(hdr))) {
    return -2;
  }
#ifdef RTNL_CHECK
  rtnl_entry_check(rtas, IFLA_MAX + 1, ns_ifmap, "link");
#endif

#ifdef FLEXIWAN_FIX
  /*  When link goes down, routes are deleted on linux side,
      but RTM_DELROUTE messages are not sent to avoid enormous amount
      of messages on systems with thousands of routes.
      So we need to clean up related routes ourself.
  */
  if (!(ifi->ifi_flags & IFF_UP)) {
    ns_route_t *route;
    pool_foreach(route, ns->netns.routes) {
        if (route->oif == ifi->ifi_index)
          ns_del_route(ns, route);
    };
  }
#endif /* FLEXIWAN_FIX */

  link = ns_get_link(ns, ifi, rtas);

  if (hdr->nlmsg_type == RTM_DELLINK) {
    if (!link)
      return -3;
    pool_put(ns->netns.links, link);
    netns_notify(ns, link, NETNS_TYPE_LINK, NETNS_F_DEL);
    return 0;
  }

  if (!link) {
    pool_get(ns->netns.links, link);
    rtnl_entry_set(link, rtas, ns_ifmap, 1);
  } else {
    rtnl_entry_set(link, rtas, ns_ifmap, 0);
  }

  link->ifi = *ifi;
  link->last_updated = vlib_time_now(vlib_get_main());
  netns_notify(ns, link, NETNS_TYPE_LINK, NETNS_F_ADD);
  return 0;
}

static void
ns_del_route(netns_p *ns, ns_route_t *route)
{
    if (route->fri != INDEX_INVALID) {
      ns_fib_reference_t* fr = pool_elt_at_index(ns->netns.fib_refs, route->fri);

      fr->ref_counter--;
      if (rtnl_debug_is_enabled())
        clib_warning("refCounter=%d: %U", fr->ref_counter, format_ns_route, route);

      if (fr->ref_counter == 0) {
        pool_put_index(ns->netns.fib_refs, route->fri);
        route->fri = INDEX_INVALID;
      }
      else if (fr->ref_counter < 0) {
        clib_error("refCounter=%d: %U", fr->ref_counter, format_ns_route, route);
        route->fri = INDEX_INVALID;
      }
    }
    pool_put(ns->netns.routes, route);
    if (route->fri == INDEX_INVALID) /*if it is the only route that maps into FIB, notify FIB of the removal*/
      netns_notify(ns, route, NETNS_TYPE_ROUTE, NETNS_F_DEL);
}

static ns_route_t *
ns_get_route(netns_p *ns, struct rtmsg *rtm, struct rtattr *rtas[], int *strict_match, u32* fib_route_index)
{
  ns_route_t *route, *kernel_route = NULL;

  //This describes the values which uniquely identify a route
  struct rtmsg msg = {
    .rtm_family = 0xff,
    .rtm_dst_len = 0xff,
    .rtm_src_len = 0xff,
    .rtm_table = 0xff,
    .rtm_protocol = 0x00,   /*FLEXIWAN - Kernel and VPP FIB does not support identical rules with different protocols, so inform user of same route*/
    .rtm_type = 0xff
  };

  *strict_match = 0;
  if (fib_route_index)
    *fib_route_index = INDEX_INVALID;

  pool_foreach(route, ns->netns.routes) {
      if(mask_match(&route->rtm, rtm, &msg, sizeof(struct rtmsg)))
      {
          if (rtnl_entry_match(route, rtas, ns_routemap_kernel))
          {
            kernel_route = route;
            if (route->rtm.rtm_protocol == rtm->rtm_protocol)
              *strict_match = 1;
          }
          else if (fib_route_index && rtnl_entry_match(route, rtas, ns_routemap_fib))
          { /*'else' is important here! It prevents kernel_route and fib_route to be same route, thus avoiding mess with refCounter! */
            *fib_route_index = route - ns->netns.routes;
          }
      }
  }
  return kernel_route;
}

static int
ns_rcv_route(netns_p *ns, struct nlmsghdr *hdr)
{
  ns_route_t *route;
  struct rtmsg *rtm;
  struct rtattr *rtas[RTA_MAX + 1] = {};
  size_t datalen = hdr->nlmsg_len - NLMSG_ALIGN(sizeof(*hdr));
  u32    idx_route_in_fib = INDEX_INVALID, *p_idx;
  int    strict_match;

  if(datalen < sizeof(*rtm))
    return -1;

  rtm = NLMSG_DATA(hdr);
  if((datalen > NLMSG_ALIGN(sizeof(*rtm))) &&
     rtnl_parse_rtattr(rtas, RTA_MAX, RTM_RTA(rtm),
                       RTM_PAYLOAD(hdr))) {
    return -2;
  }
#ifdef RTNL_CHECK
  rtnl_entry_check(rtas, RTA_MAX + 1, ns_routemap, "route");
#endif
  p_idx = (hdr->nlmsg_type == RTM_NEWROUTE) ? &idx_route_in_fib : NULL;
  route = ns_get_route(ns, rtm, rtas, &strict_match, p_idx);

  if (hdr->nlmsg_type == RTM_DELROUTE) {
    if (!route)
    {
      if (rtnl_debug_is_enabled())
        clib_warning("RTM_DELROUTE: route not found: %U", format_rtnl_msg, hdr);
      return -3;
    }
    ns_del_route(ns, route);
    return 0;
  }

  /* RTM_NEWROUTE */
#ifdef FLEXIWAN_FIX
  if (route != 0)
  {
    if (hdr->nlmsg_flags & NLM_F_REPLACE) {
      ns_del_route(ns, route);
      route = 0;
    }
    else if (strict_match) {
      if (rtnl_debug_is_enabled())
        clib_warning("RTM_NEWROUTE: route exists: %U", format_rtnl_msg, hdr);
      return -5;
    }
    else {
      if (rtnl_debug_is_enabled() || idx_route_in_fib != INDEX_INVALID) {
        if (idx_route_in_fib != INDEX_INVALID) {
          ns_route_t* fib_route = pool_elt_at_index(ns->netns.routes, idx_route_in_fib);
          clib_warning("RTM_NEWROUTE: going to override route in fib %U => %U", format_ns_route, fib_route, format_rtnl_msg, hdr);
        }
        else {
          clib_warning("RTM_NEWROUTE: going to override route %U => %U", format_ns_route, route, format_rtnl_msg, hdr);
        }
      }
    }
  }
#endif /*#ifdef FLEXIWAN_FIX*/

  if (!route) {
    pool_get(ns->netns.routes, route);
    memset(route, 0, sizeof(*route));
    route->fri = INDEX_INVALID;
    route->ns  = &ns->netns;
    rtnl_entry_set(route, rtas, ns_routemap, 1);
  } else {
    rtnl_entry_set(route, rtas, ns_routemap, 0);
  }

  route->rtm = *rtm;
  route->last_updated = vlib_time_now(vlib_get_main());

#ifdef FLEXIWAN_FIX
  /* Block installation of scope link routes caused by assigning address to interface
     and taking interface UP by kernel. We do it because VPP probably installs thems
     automatically, and we don't want to stress FIB by duplicated rules.
     See examples of blocked routes, note "scope=253" and absence of "via":

        ns_recv_rtnl:935: nlmsghdr: len=60, type=24, flags=600, seq=0, pid=0 nlmsg: RTM_NEWROUTE: rtmsg: family=INET, dst_len=32, src_len=0, tos=0, table=255, protocol=RTPROT_KERNEL/2, scope=254, type=2, flags= rtattrs: 192.168.2.171/32 oif 22 src 192.168.2.171 table 255
        ns_recv_rtnl:875: nlmsghdr: len=60, type=24, flags=600, seq=0, pid=0 nlmsg: RTM_NEWROUTE: rtmsg: family=INET, dst_len=32, src_len=0, tos=0, table=255, protocol=RTPROT_KERNEL/2, scope=253, type=3, flags= rtattrs: 192.168.10.255/32 oif 5 src 192.168.10.5 table 255
        ns_recv_rtnl:875: nlmsghdr: len=60, type=24, flags=600, seq=0, pid=0 nlmsg: RTM_NEWROUTE: rtmsg: family=INET, dst_len=24, src_len=0, tos=0, table=254, protocol=RTPROT_KERNEL/2, scope=253, type=1, flags= rtattrs: 192.168.10.0/24 oif 5 src 192.168.10.5 table 254
        ns_recv_rtnl:875: nlmsghdr: len=68, type=24, flags=600, seq=81, pid=504 nlmsg: RTM_NEWROUTE: rtmsg: family=INET, dst_len=32, src_len=0, tos=0, table=254, protocol=RTPROT_DHCP/16, scope=253, type=1, flags= rtattrs: 192.168.10.1/32 oif 5 src 192.168.10.5 table 254 priority 10
        ns_recv_rtnl:875: nlmsghdr: len=68, type=24, flags=600, seq=82, pid=504 nlmsg: RTM_NEWROUTE: rtmsg: family=INET, dst_len=0, src_len=0, tos=0, table=254, protocol=RTPROT_DHCP/16, scope=0, type=1, flags= rtattrs: 0.0.0.0/0 via 192.168.10.1 oif 5 src 192.168.10.5 table 254 priority 10
        add_del_neigh:211: sw_if_index 1, 192.168.10.1, 00:0c:29:2c:67:1c, is_del 0
        ns_recv_rtnl:875: nlmsghdr: len=68, type=25, flags=0, seq=90, pid=504 nlmsg: RTM_DELROUTE: rtmsg: family=INET, dst_len=32, src_len=0, tos=0, table=254, protocol=RTPROT_DHCP/16, scope=253, type=1, flags= rtattrs: 192.168.10.1/32 oif 5 src 192.168.10.5 table 254 priority 10

     "scope=253" stands for "scope link" rules added by kernel automatically
     on assigning address to interface:

        default via 192.168.10.1 dev eth0 proto dhcp src 192.168.10.7 metric 100
        192.168.10.0/24 dev eth0 proto kernel scope link src 192.168.10.7
        192.168.10.1 dev eth0 proto dhcp scope link src 192.168.10.7 metric 100

     As we do use scope link rules (to allow VRRP Virtual IP that does not belong to real subnet),
     we block only those link scope rules that have prefix in subnet of interface address.

     Note, we block here and not earlier in this function to have parsed NETLINK message (rtnl_entry_set()).
  */
  if (route->rtm.rtm_scope != RT_SCOPE_UNIVERSE) /*Block all but UNIVERSE (0). Others are SITE, LINK, HOST, NOWHERE. */
  {
	  ip4_main_t*       im = &ip4_main;
    ip_lookup_main_t *lm = &im->lookup_main;
    ip4_address_t     route_if_addr, route_addr, *if_addr;
    ip4_address_fib_t       fib_addr;
    u32                     if_address_index;
    ip_interface_address_t* ia;


    ip4_address_decode(route->dst, &route_addr);
    ip4_address_decode(route->prefsrc, &route_if_addr);

    ip4_addr_fib_init (&fib_addr, &route_if_addr, 0 /*fib_index*/);
    if_address_index = ip_interface_address_find (lm, &fib_addr, 0/*address_length - unused*/);
    if (if_address_index != ~0)   /*NO LOCK PROTECTION ON NOT ATOMIC OPERATION !!! TAKE A CARE OF THIS ON DEMAND :(*/
    {
	    ia = pool_elt_at_index (lm->if_address_pool, if_address_index);
      if_addr = ip4_interface_address_matching_destination (im, &route_addr, ia->sw_if_index, NULL/*ia*/);
      if (if_addr)
      {
        if (rtnl_debug_is_enabled())
          clib_warning("RTM_NEWROUTE: ignore link scope route for interface subnet destinations: %U", format_rtnl_msg, hdr);
        pool_put(ns->netns.routes, route);
        return 0;
      }
    }
  }
#endif

#ifdef FLEXIWAN_FIX
  /* If new route is mapped into FIB entry that was isntalled earlier
     for the other route, update refCounter and don't notify FIB.
  */
  if (idx_route_in_fib != INDEX_INVALID)
  {
    ns_route_t* fib_route = pool_elt_at_index(ns->netns.routes, idx_route_in_fib);
    ns_fib_reference_t* fr;

    /* Lazy allocation of the refCounter: we allocate it only when
       we are going to add the second route that maps into existing FIB entry,
       i.e. when 'fib_route' was found.
    */
    if (fib_route->fri == INDEX_INVALID)
    {
      pool_get(ns->netns.fib_refs, fr);
      fib_route->fri  = fr - ns->netns.fib_refs;
      fr->ref_counter = 1;
    } else {
      fr = pool_elt_at_index(ns->netns.fib_refs, fib_route->fri);
    }
    route->fri = fib_route->fri;
    fr->ref_counter++;
    if (rtnl_debug_is_enabled())
      clib_warning("RTM_NEWROUTE: refCounter=%d: %U , fib_route: %U",
        fr->ref_counter, format_rtnl_msg, hdr, format_ns_route, fib_route);
    return 0;
  }
#endif /*#ifdef FLEXIWAN_FIX*/

  netns_notify(ns, route, NETNS_TYPE_ROUTE, NETNS_F_ADD);
  return 0;
}

static ns_addr_t *
ns_get_addr(netns_p *ns, struct ifaddrmsg *ifaddr, struct rtattr *rtas[])
{
  ns_addr_t *addr;

  //This describes the values which uniquely identify a route
  struct ifaddrmsg msg = {
    .ifa_family = 0xff,
    .ifa_prefixlen = 0xff,
  };

  pool_foreach(addr, ns->netns.addresses) {
      if(mask_match(&addr->ifaddr, ifaddr, &msg, sizeof(struct ifaddrmsg)) &&
         rtnl_entry_match(addr, rtas, ns_addrmap))
        return addr;
    };
  return NULL;
}

static int
ns_rcv_addr(netns_p *ns, struct nlmsghdr *hdr)
{
  ns_addr_t *addr;
  struct ifaddrmsg *ifaddr;
  struct rtattr *rtas[IFA_MAX + 1] = {};
  size_t datalen = hdr->nlmsg_len - NLMSG_ALIGN(sizeof(*hdr));

  if(datalen < sizeof(*ifaddr))
    return -1;

  ifaddr = NLMSG_DATA(hdr);
  if((datalen > NLMSG_ALIGN(sizeof(*ifaddr))) &&
     rtnl_parse_rtattr(rtas, IFA_MAX, IFA_RTA(ifaddr),
                       IFA_PAYLOAD(hdr))) {
    return -2;
  }
#ifdef RTNL_CHECK
  rtnl_entry_check(rtas, IFA_MAX + 1, ns_addrmap, "addr");
#endif
  addr = ns_get_addr(ns, ifaddr, rtas);

  if (hdr->nlmsg_type == RTM_DELADDR) {
    if (!addr)
      return -3;
    pool_put(ns->netns.addresses, addr);
    netns_notify(ns, addr, NETNS_TYPE_ADDR, NETNS_F_DEL);
    return 0;
  }

  if (!addr) {
    pool_get(ns->netns.addresses, addr);
    memset(addr, 0, sizeof(*addr));
    rtnl_entry_set(addr, rtas, ns_addrmap, 1);
  } else {
    rtnl_entry_set(addr, rtas, ns_addrmap, 0);
  }

  addr->ifaddr = *ifaddr;
  addr->last_updated = vlib_time_now(vlib_get_main());
  netns_notify(ns, addr, NETNS_TYPE_ADDR, NETNS_F_ADD);
  return 0;
}

static ns_neigh_t *
ns_get_neigh(netns_p *ns, struct ndmsg *nd, struct rtattr *rtas[])
{
  ns_neigh_t *neigh;

  //This describes the values which uniquely identify a route
  struct ndmsg msg = {
    .ndm_family = 0xff,
    .ndm_ifindex = 0xff,
  };

  pool_foreach(neigh, ns->netns.neighbors) {
      if(mask_match(&neigh->nd, nd, &msg, sizeof(&msg)) &&
         rtnl_entry_match(neigh, rtas, ns_neighmap))
        return neigh;
    };
  return NULL;
}

static int
ns_rcv_neigh(netns_p *ns, struct nlmsghdr *hdr)
{
  ns_neigh_t *neigh;
  struct ndmsg *nd;
  struct rtattr *rtas[NDA_MAX + 1] = {};
  size_t datalen = hdr->nlmsg_len - NLMSG_ALIGN(sizeof(*hdr));

  if(datalen < sizeof(*nd))
    return -1;

  nd = NLMSG_DATA(hdr);
  if((datalen > NLMSG_ALIGN(sizeof(*nd))) &&
     rtnl_parse_rtattr(rtas, NDA_MAX, NDA_RTA(nd),
                       NDA_PAYLOAD(hdr))) {
    return -2;
  }
#ifdef RTNL_CHECK
  rtnl_entry_check(rtas, NDA_MAX + 1, ns_neighmap, "nd");
#endif
  neigh = ns_get_neigh(ns, nd, rtas);

  if (hdr->nlmsg_type == RTM_DELNEIGH) {
    if (!neigh)
      return -3;
    pool_put(ns->netns.neighbors, neigh);
    netns_notify(ns, neigh, NETNS_TYPE_NEIGH, NETNS_F_DEL);
    return 0;
  }

  if (!neigh) {
    pool_get(ns->netns.neighbors, neigh);
    memset(neigh, 0, sizeof(*neigh));
    rtnl_entry_set(neigh, rtas, ns_neighmap, 1);
  } else {
#ifdef FLEXIWAN_FIX
    /* Don't update VPP if state was not changed.
       That might create duplicate entries, while taking old entries to not-resolved state.
    */
    if (neigh->nd.ndm_state == nd->ndm_state)
      return 0;
#endif
    rtnl_entry_set(neigh, rtas, ns_neighmap, 0);
  }

  neigh->nd = *nd;
  neigh->last_updated = vlib_time_now(vlib_get_main());
  netns_notify(ns, neigh, NETNS_TYPE_NEIGH, NETNS_F_ADD);
  return 0;
}

#ifndef FLEXIWAN_FIX
#define ns_object_foreach                       \
   _(neighbors, NETNS_TYPE_NEIGH)                \
   _(routes, NETNS_TYPE_ROUTE)                   \
   _(addresses, NETNS_TYPE_ADDR)                 \
   _(links, NETNS_TYPE_LINK)
#else
#define ns_object_foreach                       \
  _(neighbors, NETNS_TYPE_NEIGH)                \
  _(addresses, NETNS_TYPE_ADDR)                 \
  _(links, NETNS_TYPE_LINK)
#endif /*#ifndef FLEXIWAN_FIX*/

static void
ns_recv_error(rtnl_error_t err, uword o)
{
  //An error was received. Reset everything.
  netns_p *ns = &netns_main.netnss[o];
  u32 *indexes = 0;
  u32 *i = 0;
  ns_route_t* route;

#define _(pool, type)                                           \
  pool_foreach_index(*i, ns->netns.pool) {                      \
      vec_add1(indexes, *i);                                    \
    }                                                           \
    vec_foreach(i, indexes) {                                   \
    pool_put_index(ns->netns.pool, *i);                         \
    netns_notify(ns, &ns->netns.pool[*i], type, NETNS_F_DEL);   \
  }                                                             \
  vec_reset_length(indexes);

  ns_object_foreach

#undef _
    vec_free(indexes);

  pool_foreach(route, ns->netns.routes)
    ns_del_route(ns, route);    // free refCounter as well
}

static void
ns_recv_rtnl(struct nlmsghdr *hdr, uword o)
{
  netns_p *ns = &netns_main.netnss[o];
  int ret = 0;

  if(rtnl_debug_is_enabled()) {
    clib_warning("%U", format_rtnl_msg, hdr);
  }

  switch (hdr->nlmsg_type) {
  case RTM_NEWROUTE:
  case RTM_DELROUTE:
    ret = ns_rcv_route(ns, hdr);
    break;
  case RTM_NEWLINK:
  case RTM_DELLINK:
    ret = ns_rcv_link(ns, hdr);
    break;
  case RTM_NEWADDR:
  case RTM_DELADDR:
    ret = ns_rcv_addr(ns, hdr);
    break;
  case RTM_NEWNEIGH:
  case RTM_DELNEIGH:
    ret = ns_rcv_neigh(ns, hdr);
    break;
  default:
    clib_warning("unknown rtnl type %d", hdr->nlmsg_type);
    break;
  }

  if (ret && rtnl_debug_is_enabled()) {
    clib_warning("%U failed: %d", format_rtnl_msg_type, hdr, ret);
  }
}

int rtnl_msg_to_ns_route(struct nlmsghdr* hdr, ns_route_t* route)
{
  struct rtmsg*  rtm               = NLMSG_DATA(hdr);
  struct rtattr* rtas[RTA_MAX + 1] = {};
  int            ret;

  memset(route, 0, sizeof(*route));
  ret = rtnl_parse_rtattr(rtas, RTA_MAX, RTM_RTA(rtm), RTM_PAYLOAD(hdr));
  if (ret)
      return ret;
  ret = rtnl_entry_set(route, rtas, ns_routemap, 1);
  if (ret)
      return ret;
  route->rtm = *rtm;
  return 0;
}

static void
netns_destroy(netns_p *ns)
{
  netns_main_t *nm = &netns_main;
  rtnl_stream_close(ns->rtnl_handle);
  pool_put(nm->netnss, ns);
  pool_free(ns->netns.links);
  pool_free(ns->netns.addresses);
  pool_free(ns->netns.routes);
  pool_free(ns->netns.fib_refs);
  pool_free(ns->netns.neighbors);
}

static netns_p *
netns_get(char *name)
{
  netns_main_t *nm = &netns_main;
  netns_p *ns;
  pool_foreach(ns, nm->netnss) {
      if (!strcmp(name, ns->netns.name))
        return ns;
    };

  if (strlen(name) > RTNL_NETNS_NAMELEN)
    return NULL;

  pool_get(nm->netnss, ns);
  rtnl_stream_t s = {
    .recv_message = ns_recv_rtnl,
    .error = ns_recv_error,
    .opaque = (uword)(ns - nm->netnss),
  };
  strcpy(s.name, name);

  u32 handle;
  if ((handle = rtnl_stream_open(&s)) == ~0) {
    pool_put(nm->netnss, ns);
    return NULL;
  }

  strcpy(ns->netns.name, name);
  ns->netns.addresses = 0;
  ns->netns.links = 0;
  ns->netns.neighbors = 0;
  ns->netns.routes = 0;
  ns->netns.fib_refs = 0;
  ns->subscriber_count = 0;
  ns->rtnl_handle = handle;
  return ns;
}

u32 netns_open(char *name, netns_sub_t *sub)
{
  netns_main_t *nm = &netns_main;
  netns_p *ns;
  netns_handle_t *p;
  if (!(ns = netns_get(name)))
    return ~0;

  pool_get(nm->handles, p);
  p->netns_index = ns - nm->netnss;
  p->notify = sub->notify;
  p->opaque = sub->opaque;
  ns->subscriber_count++;
  return p - nm->handles;
}

netns_t *netns_getns(u32 handle)
{
  netns_main_t *nm = &netns_main;
  netns_handle_t *h = pool_elt_at_index(nm->handles, handle);
  netns_p *ns = pool_elt_at_index(nm->netnss, h->netns_index);
  return &ns->netns;
}

void netns_close(u32 handle)
{
  netns_main_t *nm = &netns_main;
  netns_handle_t *h = pool_elt_at_index(nm->handles, handle);
  netns_p *ns = pool_elt_at_index(nm->netnss, h->netns_index);
  pool_put(h, nm->handles);
  ns->subscriber_count--;
  if (!ns->subscriber_count)
    netns_destroy(ns);
}

void netns_callme(u32 handle, char del)
{
  netns_main_t *nm = &netns_main;
  netns_handle_t *h = pool_elt_at_index(nm->handles, handle);
  netns_p *ns = pool_elt_at_index(nm->netnss, h->netns_index);
  u32 i = 0;
  if (!h->notify)
    return;

#define _(pool, type)                                           \
  pool_foreach_index(i, ns->netns.pool) {                       \
      h->notify(&ns->netns.pool[i], type,                       \
                del?NETNS_F_DEL:NETNS_F_ADD, h->opaque);        \
    };

  ns_object_foreach
#undef _

    }

u8 *format_ns_object(u8 *s, va_list *args)
{
  netns_type_t t = va_arg(*args, netns_type_t);
  void *o = va_arg(*args, void *);
  switch (t) {
  case NETNS_TYPE_ADDR:
    return format(s, "addr %U", format_ns_addr, o);
  case NETNS_TYPE_ROUTE:
    return format(s, "route %U", format_ns_route, o);
  case NETNS_TYPE_LINK:
    return format(s, "link %U", format_ns_link, o);
  case NETNS_TYPE_NEIGH:
    return format(s, "neigh %U", format_ns_neigh, o);
  }
  return s;
}

u8 *format_ns_flags(u8 *s, va_list *args)
{
  u32 flags = va_arg(*args, u32);
  if (flags & NETNS_F_ADD)
    s = format(s, "add");
  else if (flags & NETNS_F_DEL)
    s = format(s, "del");
  else
    s = format(s, "mod");
  return s;
}

clib_error_t *
netns_init (vlib_main_t * vm)
{
  netns_main_t *nm = &netns_main;
  nm->netnss = 0;
  nm->handles = 0;
  return 0;
}

VLIB_INIT_FUNCTION (netns_init);

static clib_error_t *
show_tap_inject_routes_cli (vlib_main_t * vm, unformat_input_t * input,
                            vlib_cli_command_t * cmd)
{
  ns_route_t *route;
  netns_main_t *nm = &netns_main;
  netns_p *ns;
  uint32_t i = 0;

  pool_foreach(ns, nm->netnss)
    {
      pool_foreach(route, ns->netns.routes)
      {
        vlib_cli_output(vm, "[%u]: %U \n", i, format_ns_route, route);
        i++;
      }
    }

  return 0;
}

VLIB_CLI_COMMAND (show_tap_inject_routes_cmd, static) = {
  .path = "show tap-inject routes",
  .short_help = "show tap-inject routes",
  .function = show_tap_inject_routes_cli,
};
