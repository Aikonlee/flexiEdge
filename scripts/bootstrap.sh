#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[bootstrap] Please run as root (sudo)." >&2
  exit 1
fi

APT_PACKAGES=(
  xorriso
  squashfs-tools
  cloud-image-utils
  genisoimage
  p7zip-full
  wget
  curl
  ca-certificates
  python3-yaml
  python3-jinja2
  apt-transport-https
  apt-rdepends
)

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "${APT_PACKAGES[@]}"

echo "[bootstrap] Toolchain ready."