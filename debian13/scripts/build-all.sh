#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FLEXI_VERSION="6.5.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      export FLEXI_VERSION="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--version 6.5.1]"
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== Building flexiEdge Debian 13 ISO (version: $FLEXI_VERSION) ==="
"$ROOT_DIR/scripts/01-fetch-components.sh"
"$ROOT_DIR/scripts/02-build-rootfs.sh"
"$ROOT_DIR/scripts/03-build-installer-live.sh"
"$ROOT_DIR/scripts/04-build-iso.sh"
echo "=== Build Complete ==="
