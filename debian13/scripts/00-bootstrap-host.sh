#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# Switch Ubuntu apt sources from http:// to https:// to avoid HTTP port 80 400 errors
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  sed -i \
    -e 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g' \
    -e 's|http://security.ubuntu.com|https://security.ubuntu.com|g' \
    /etc/apt/sources.list.d/ubuntu.sources
fi
apt-get update
apt-get install -y \
  ca-certificates \
  debian-archive-keyring \
  debootstrap \
  squashfs-tools \
  xorriso \
  grub-efi-amd64-bin \
  grub-common \
  mtools \
  dosfstools \
  gdisk \
  parted \
  git \
  curl \
  wget \
  jq \
  rsync \
  python3 \
  qemu-system-x86 \
  ovmf

echo "[bootstrap] Host dependencies installed successfully."
