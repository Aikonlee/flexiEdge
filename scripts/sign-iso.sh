#!/usr/bin/env bash
set -euo pipefail

ISO_PATH=""
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
Usage: GPG_KEY_ID=<key-id> scripts/sign-iso.sh [--output FILE] <iso-path>

Produces a GPG detached ASCII-armored signature (.asc) for an ISO artifact using
GPG_KEY_ID from the environment. No keys or passphrases are stored in this repo.

Environment:
  GPG_KEY_ID      Required. GPG key ID or fingerprint to sign with.

Options:
  --output FILE   Override output signature path (default: <iso-path>.asc).
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"; shift 2;;
    --output=*)
      OUTPUT_PATH="${1#*=}"; shift;;
    -h|--help)
      usage; exit 0;;
    -*)
      echo "[sign-iso] Unknown option: $1" >&2
      usage
      exit 1;;
    *)
      if [[ -n "$ISO_PATH" ]]; then
        echo "[sign-iso] Unexpected positional argument: $1" >&2
        usage
        exit 1
      fi
      ISO_PATH="$1"; shift;;
  esac
done

if [[ -z "$ISO_PATH" ]]; then
  echo "[sign-iso] ERROR: ISO path is required." >&2
  usage
  exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
  echo "[sign-iso] ERROR: ISO file not found: $ISO_PATH" >&2
  exit 1
fi

if [[ -z "${GPG_KEY_ID:-}" ]]; then
  echo "[sign-iso] ERROR: GPG_KEY_ID environment variable must be set." >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  echo "[sign-iso] ERROR: gpg command not found." >&2
  exit 1
fi

[[ -n "$OUTPUT_PATH" ]] || OUTPUT_PATH="${ISO_PATH}.asc"

echo "[sign-iso] Signing $ISO_PATH with key $GPG_KEY_ID"
gpg --armor --detach-sign --local-user "$GPG_KEY_ID" --output "$OUTPUT_PATH" "$ISO_PATH"

echo "[sign-iso] Detached signature written to $OUTPUT_PATH"
