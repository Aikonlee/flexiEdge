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
rsync -a --delete --exclude='.git' --exclude='/build-root/' "$WORK_DIR/repos/flexiRouterVPP/" "$BUILD_ROOTFS/build/vpp/"
rsync -a --delete --exclude='.git' "$WORK_DIR/repos/flexiRouterSB/" "$BUILD_ROOTFS/build/vppsb/"

# Integrate the sideband plugin before VPP discovers its plugin targets.
PLUGIN_SRC="$BUILD_ROOTFS/build/vpp/src/plugins"
mkdir -p "$PLUGIN_SRC/router" "$PLUGIN_SRC/netlink/librtnl"
rsync -a "$BUILD_ROOTFS/build/vppsb/router/" "$PLUGIN_SRC/router/"
rsync -a "$BUILD_ROOTFS/build/vppsb/netlink/librtnl/" "$PLUGIN_SRC/netlink/librtnl/"

# Debian installs libnl headers in a non-default include directory.
cat >> "$PLUGIN_SRC/router/CMakeLists.txt" <<'CMAKE'
find_package(PkgConfig REQUIRED)
pkg_check_modules(ROUTER_LIBNL REQUIRED IMPORTED_TARGET libnl-route-3.0)
target_link_libraries(router_plugin PkgConfig::ROUTER_LIBNL)
CMAKE

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
  make pkg-deb
'

echo "[01b-build-vpp] Copying built .deb packages to $OUT_DEBS..."
DEB_DIR="$BUILD_ROOTFS/build/vpp/build-root"
shopt -s nullglob
core_debs=("$DEB_DIR"/vpp-plugin-core_*.deb)
if (( ${#core_debs[@]} != 1 )); then
  echo '[01b-build-vpp] ERROR: Expected one vpp-plugin-core package.' >&2
  exit 1
fi
dpkg-deb -c "${core_debs[0]}" | grep '/vpp_plugins/router_plugin\.so$' >/dev/null || {
  echo '[01b-build-vpp] ERROR: Built package is missing router_plugin.so.' >&2
  exit 1
}
plugin_check=$(mktemp -d)
dpkg-deb -x "${core_debs[0]}" "$plugin_check"
router_plugin=$(find "$plugin_check" -type f -name router_plugin.so -print -quit)
if [[ -z "$router_plugin" ]] || ! grep -aF 'tap-inject enable-ip4-output interface' "$router_plugin" >/dev/null; then
  echo '[01b-build-vpp] ERROR: router plugin lacks the required WAN TAP output CLI.' >&2
  exit 1
fi
for pkg in libvppinfra vpp vpp-plugin-core vpp-plugin-dpdk python3-vpp-api; do
  files=("$DEB_DIR"/"${pkg}"_*.deb)
  (( ${#files[@]} == 1 )) || { echo "[01b-build-vpp] ERROR: Expected one $pkg package." >&2; exit 1; }
  cp -v "${files[0]}" "$OUT_DEBS/"
done
