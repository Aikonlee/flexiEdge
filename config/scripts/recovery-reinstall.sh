#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[flexiwan-recovery] Please run as root." >&2
  exit 1
fi

SCRIPT_CANDIDATES=(
  "/cdrom/nocloud/setup-flexiwan.sh"
  "/usr/local/sbin/flexiwan-setup"
  "/var/lib/flexiwan/install-cache/setup-flexiwan.sh"
)

for candidate in "${SCRIPT_CANDIDATES[@]}"; do
  if [[ -x "$candidate" ]]; then
    echo "[flexiwan-recovery] Re-running $candidate --reconfigure"
    exec "$candidate" --reconfigure "$@"
  fi
done

echo "[flexiwan-recovery] Unable to locate a setup script. Mount the flexiEdge ISO and retry." >&2
exit 1
