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
rsync -a --delete --exclude='.git' "$WORK_DIR/repos/flexiRouterVPP/" "$BUILD_ROOTFS/build/vpp/"
rsync -a --delete --exclude='.git' "$WORK_DIR/repos/flexiRouterSB/" "$BUILD_ROOTFS/build/vppsb/"

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
find "$BUILD_ROOTFS/build/vpp/build-root" -maxdepth 2 -name '*.deb' -exec cp -v {} "$OUT_DEBS/" \;
ls -lh "$OUT_DEBS"/*.deb || echo "[01b-build-vpp] WARNING: No .deb files found"
