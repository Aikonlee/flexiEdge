#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[flexiwan-recovery] Please run as root." >&2
  exit 1
fi

echo "[flexiwan-recovery] Launching flexiWAN offline recovery installer..."
if [[ -x /usr/local/sbin/flexiwan-installer.sh ]]; then
  exec /usr/local/sbin/flexiwan-installer.sh "$@"
fi

echo "[flexiwan-recovery] Installer not found. Please boot into 'flexiWAN Recovery (Offline Reinstall)' from GRUB." >&2
exit 1
