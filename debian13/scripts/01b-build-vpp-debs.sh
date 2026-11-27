#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[01b-build-vpp] Please run as root (sudo)." >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$ROOT_DIR/.work"
BUILD_ROOTFS="$WORK_DIR/vpp-builder-rootfs"
OUT_DEBS="$ROOT_DIR/cache/packages"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
SUITE="trixie"

[[ -d "$WORK_DIR/repos/flexiRouterVPP" ]] || { echo "Run 01-fetch-components.sh first." >&2; exit 1; }

cleanup_mounts() {
  if [[ -n ${plugin_check:-} ]]; then rm -rf -- "$plugin_check"; fi
  for fs in run sys proc dev/pts dev; do
    mountpoint -q "$BUILD_ROOTFS/$fs" && umount -lf "$BUILD_ROOTFS/$fs" || true
  done
}
trap cleanup_mounts EXIT

if [[ ! -d "$BUILD_ROOTFS/usr" ]]; then
  echo "[01b-build-vpp] Bootstrapping Debian 13 ($SUITE) VPP build chroot..."
  mkdir -p "$BUILD_ROOTFS"
  debootstrap --arch=amd64 --variant=minbase --include=ca-certificates "$SUITE" "$BUILD_ROOTFS" "$DEBIAN_MIRROR"
fi

for fs in dev dev/pts proc sys run; do
  mountpoint -q "$BUILD_ROOTFS/$fs" || mount --bind "/$fs" "$BUILD_ROOTFS/$fs"
done

mkdir -p "$BUILD_ROOTFS/build" "$OUT_DEBS"
rsync -a --delete --exclude='/build-root/' "$WORK_DIR/repos/flexiRouterVPP/" "$BUILD_ROOTFS/build/vpp/"
rsync -a --delete --exclude='.git' "$WORK_DIR/repos/flexiRouterSB/" "$BUILD_ROOTFS/build/vppsb/"

# Integrate the sideband plugin before VPP discovers its plugin targets.
PLUGIN_SRC="$BUILD_ROOTFS/build/vpp/src/plugins"
mkdir -p "$PLUGIN_SRC/router" "$PLUGIN_SRC/netlink/librtnl"
rsync -a "$BUILD_ROOTFS/build/vppsb/router/" "$PLUGIN_SRC/router/"
rsync -a "$BUILD_ROOTFS/build/vppsb/netlink/librtnl/" "$PLUGIN_SRC/netlink/librtnl/"

echo "[01b-build-vpp] Installing VPP build dependencies and compiling .deb packages..."
chroot "$BUILD_ROOTFS" /bin/bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  export UNATTENDED=y
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential git curl wget sudo python3 python3-dev \
    cmake ninja-build pkg-config debhelper dh-python \
    libssl-dev libnuma-dev libnl-3-dev libnl-route-3-dev \
    nasm uuid-dev libmnl-dev libelf-dev bison flex

  cd /build/vpp
  # Install upstream VPP build deps if supported on trixie
  make install-dep || true
  export CFLAGS="${CFLAGS:+${CFLAGS} }-DFLEXIWAN_FEATURE"
  export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-DFLEXIWAN_FEATURE"
  echo "[01b-build-vpp] Build flags: CFLAGS=${CFLAGS} CXXFLAGS=${CXXFLAGS}"
  # Have debhelper preserve the ELF symbols in the packaged libraries.
  export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+${DEB_BUILD_OPTIONS} }nostrip"
  make pkg-deb
'

echo "[01b-build-vpp] Running build gates on generated .deb packages..."
DEB_DIR="$BUILD_ROOTFS/build/vpp/build-root"
shopt -s nullglob
vpp_debs=("$DEB_DIR"/vpp_*.deb)
if (( ${#vpp_debs[@]} != 1 )); then
  echo '[01b-build-vpp] ERROR: Expected one vpp package.' >&2
  exit 1
fi
core_debs=("$DEB_DIR"/vpp-plugin-core_*.deb)
if (( ${#core_debs[@]} != 1 )); then
  echo '[01b-build-vpp] ERROR: Expected one vpp-plugin-core package.' >&2
  exit 1
fi

plugin_check=$(mktemp -d)
mkdir -p "$plugin_check/vpp" "$plugin_check/core"
dpkg-deb -x "${vpp_debs[0]}" "$plugin_check/vpp"
dpkg-deb -x "${core_debs[0]}" "$plugin_check/core"

# Gate 1: VPP core API JSON must contain flexiWAN interface flags extension.
api_json=""
for candidate in \
  "$plugin_check/vpp/usr/share/vpp/api/core/interface.api.json" \
  "$plugin_check/core/usr/share/vpp/api/core/interface.api.json"; do
  if [[ -f "$candidate" ]]; then
    api_json="$candidate"
    break
  fi
done
if [[ -z "$api_json" ]]; then
  echo '[01b-build-vpp] ERROR: Built vpp/vpp-plugin-core deb is missing usr/share/vpp/api/core/interface.api.json.' >&2
  exit 1
fi
if ! grep -q 'flexiwan_flags' "$api_json"; then
  echo "[01b-build-vpp] ERROR: $api_json is missing required 'flexiwan_flags' API extension." >&2
  exit 1
fi
if ! grep -q 'vl_api_if_flexiwan_flags_t' "$api_json"; then
  echo "[01b-build-vpp] ERROR: $api_json is missing required 'vl_api_if_flexiwan_flags_t' API type." >&2
  exit 1
fi

# Gate 2: vpp-plugin-core must ship router.so with symlinks router.so.0 and router.so.0.0.0.
router_so=$(find "$plugin_check/core" -path '*/vpp_plugins/router.so' -print -quit)
if [[ -z "$router_so" ]]; then
  router_plugin_only=$(find "$plugin_check/core" -path '*/vpp_plugins/router_plugin.so' -print -quit)
  if [[ -n "$router_plugin_only" ]]; then
    echo '[01b-build-vpp] ERROR: Only router_plugin.so found in vpp-plugin-core; expected router.so with symlinks router.so.0 and router.so.0.0.0.' >&2
  else
    echo '[01b-build-vpp] ERROR: Built vpp-plugin-core package is missing vpp_plugins/router.so.' >&2
  fi
  exit 1
fi

plugin_dir=$(dirname "$router_so")
router_so_0="$plugin_dir/router.so.0"
router_so_000="$plugin_dir/router.so.0.0.0"

if [[ ! -e "$router_so" || ! -f "$router_so" ]]; then
  echo '[01b-build-vpp] ERROR: vpp_plugins/router.so is not a valid readable file (or is a dangling symlink).' >&2
  exit 1
fi
if [[ ! -e "$router_so_0" || ! -e "$router_so_000" ]]; then
  echo '[01b-build-vpp] ERROR: Missing required symlinks router.so.0 and/or router.so.0.0.0 alongside router.so.' >&2
  exit 1
fi

symlink_count=0
for entry in "$router_so" "$router_so_0" "$router_so_000"; do
  if [[ -L "$entry" ]]; then
    symlink_count=$((symlink_count + 1))
  fi
done
if (( symlink_count < 2 )); then
  echo '[01b-build-vpp] ERROR: Expected router.so with symlinks router.so.0 and router.so.0.0.0 (found fewer than 2 symlinks).' >&2
  exit 1
fi

router_real=$(readlink -f "$router_so")
router_real_0=$(readlink -f "$router_so_0")
router_real_000=$(readlink -f "$router_so_000")
if [[ -z "$router_real" || "$router_real" != "$router_real_0" || "$router_real" != "$router_real_000" ]]; then
  echo '[01b-build-vpp] ERROR: router.so, router.so.0, and router.so.0.0.0 do not resolve to the same target file.' >&2
  exit 1
fi

# Gate 3: check defined dynamic exports and the shared netlink dependency.
router_exports="$plugin_check/router.exports"
router_dynamic="$plugin_check/router.dynamic"
nm -D --defined-only "$router_real" > "$router_exports"
for symbol in vlib_plugin_registration tap_inject_rx_node tap_inject_tx_node tap_inject_enable_netlink; do
  if ! awk -v symbol="$symbol" '$NF == symbol { found = 1 } END { exit !found }' "$router_exports"; then
    echo "[01b-build-vpp] ERROR: router.so lacks required dynamic export '$symbol'." >&2
    exit 1
  fi
done
LC_ALL=C readelf -d "$router_real" > "$router_dynamic"
if ! grep -Eq '\(NEEDED\).*\[librtnl\.so\.0\]$' "$router_dynamic"; then
  echo '[01b-build-vpp] ERROR: router.so lacks required DT_NEEDED entry librtnl.so.0.' >&2
  exit 1
fi

router_strings="$plugin_check/router.strings"
strings "$router_real" > "$router_strings"
if ! grep -qF 'tap-inject enable-ip4-output interface' "$router_strings"; then
  echo '[01b-build-vpp] ERROR: router.so lacks required tap-inject CLI text (tap-inject enable-ip4-output interface).' >&2
  exit 1
fi

echo "[01b-build-vpp] Build gates passed. Checked artifact SHA256 checksums:"
sha256sum "$api_json" "$router_so" "$router_real" "${vpp_debs[0]}" "${core_debs[0]}"

echo "[01b-build-vpp] Copying built .deb packages to $OUT_DEBS..."
for pkg in libvppinfra vpp vpp-plugin-core vpp-plugin-dpdk python3-vpp-api; do
  files=("$DEB_DIR"/"${pkg}"_*.deb)
  (( ${#files[@]} == 1 )) || { echo "[01b-build-vpp] ERROR: Expected one $pkg package." >&2; exit 1; }
  cp -v "${files[0]}" "$OUT_DEBS/"
done
