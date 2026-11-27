# Copyright (c) 2018 Cisco and/or its affiliates.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

include_directories (
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/../netlink
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(ROUTER_LIBNL REQUIRED IMPORTED_TARGET libnl-route-3.0)

# Build the sideband netlink library with the SONAME expected by router.so.
add_library(router_rtnl SHARED
  ../netlink/librtnl/mapper.c
  ../netlink/librtnl/netns.c
  ../netlink/librtnl/rtnl.c
)
set_target_properties(router_rtnl PROPERTIES
  OUTPUT_NAME rtnl
  SOVERSION 0
)
target_link_libraries(router_rtnl PRIVATE PkgConfig::ROUTER_LIBNL)
install(TARGETS router_rtnl
  LIBRARY DESTINATION ${VPP_LIBRARY_DIR}
  COMPONENT vpp-plugin-core
  NAMELINK_SKIP
)

# The package script copies the sideband router directory into src/plugins/router.
set(router_source_dir router)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tap_inject.c")
  set(router_source_dir ".")
endif()

add_vpp_plugin(router
  SOURCES
  ${router_source_dir}/tap_inject.c
  ${router_source_dir}/tap_inject_netlink.c
  ${router_source_dir}/tap_inject_node.c
  ${router_source_dir}/tap_inject_tap.c
  LINK_LIBRARIES router_rtnl PkgConfig::ROUTER_LIBNL
)

# The plugin macro supplies a literal -fvisibility=hidden option.
get_target_property(router_compile_options router_plugin COMPILE_OPTIONS)
list(REMOVE_ITEM router_compile_options "-fvisibility=hidden")
set_target_properties(router_plugin PROPERTIES
  COMPILE_OPTIONS "${router_compile_options}"
  PREFIX ""
  OUTPUT_NAME router
  NO_SONAME 0
  SOVERSION 0
  VERSION 0.0.0
  INSTALL_RPATH "$ORIGIN/.."
)
target_compile_options(router_plugin PRIVATE "-fvisibility=default")
