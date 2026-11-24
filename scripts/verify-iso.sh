#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ISO_PATH="${ISO_PATH:-}"
SHA256_PATH="${SHA256_PATH:-}"
MANIFEST_PATH="${MANIFEST_PATH:-}"
SKIP_SHELL_CHECK=0

usage() {
  cat <<'EOF'
Usage: scripts/verify-iso.sh [options]

Validates repository shell scripts (bash -n), checks that an ISO artifact and
its matching .sha256 file exist and verify cleanly, and validates manifest.json
with python3 -m json.tool.

Options:
  --iso FILE          Path to ISO file to verify (or set ISO_PATH).
  --sha256 FILE       Path to .sha256 file (defaults to <iso>.sha256 or SHA256_PATH).
  --manifest FILE     Path to manifest.json to validate (or set MANIFEST_PATH).
  --skip-shell-check  Skip bash -n syntax validation of repository shell scripts.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      ISO_PATH="$2"; shift 2;;
    --iso=*)
      ISO_PATH="${1#*=}"; shift;;
    --sha256)
      SHA256_PATH="$2"; shift 2;;
    --sha256=*)
      SHA256_PATH="${1#*=}"; shift;;
    --manifest)
      MANIFEST_PATH="$2"; shift 2;;
    --manifest=*)
      MANIFEST_PATH="${1#*=}"; shift;;
    --skip-shell-check)
      SKIP_SHELL_CHECK=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "[verify-iso] Unknown option: $1" >&2
      usage
      exit 1;;
  esac
done

if [[ $SKIP_SHELL_CHECK -eq 0 ]]; then
  echo "[verify-iso] Checking shell script syntax with bash -n"
  mapfile -t shell_scripts < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/config/scripts" -maxdepth 2 -type f -name '*.sh' | sort)
  if [[ ${#shell_scripts[@]} -eq 0 ]]; then
    echo "[verify-iso] ERROR: No shell scripts found under scripts/ or config/scripts/" >&2
    exit 1
  fi
  for script in "${shell_scripts[@]}"; do
    bash -n "$script"
    echo "[verify-iso] OK: bash -n ${script#"$ROOT_DIR"/}"
  done
fi

if [[ -z "$ISO_PATH" ]]; then
  echo "[verify-iso] ERROR: ISO path is required (--iso or ISO_PATH)" >&2
  usage
  exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
  echo "[verify-iso] ERROR: ISO file not found: $ISO_PATH" >&2
  exit 1
fi

if [[ ! -s "$ISO_PATH" ]]; then
  echo "[verify-iso] ERROR: ISO file is empty: $ISO_PATH" >&2
  exit 1
fi

if [[ -z "$SHA256_PATH" ]]; then
  SHA256_PATH="${ISO_PATH}.sha256"
fi

if [[ ! -f "$SHA256_PATH" ]]; then
  echo "[verify-iso] ERROR: Matching .sha256 file not found: $SHA256_PATH" >&2
  exit 1
fi

echo "[verify-iso] Verifying SHA-256 checksum for $ISO_PATH"
ISO_BASE=$(basename "$ISO_PATH")
SHA256_ABS=$(cd "$(dirname "$SHA256_PATH")" && pwd)/$(basename "$SHA256_PATH")

EXPECTED_SHA256=""
MATCH_COUNT=0
SHA256_LINE_RE='^([0-9a-fA-F]{64}) [ *](.+)$'
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ $SHA256_LINE_RE ]]; then
    entry_hash="${BASH_REMATCH[1],,}"
    entry_file="${BASH_REMATCH[2]}"
    if [[ "$entry_file" == "$ISO_BASE" ]]; then
      EXPECTED_SHA256="$entry_hash"
      MATCH_COUNT=$((MATCH_COUNT + 1))
    fi
  fi
done <"$SHA256_ABS"

if [[ $MATCH_COUNT -eq 0 ]]; then
  echo "[verify-iso] ERROR: $SHA256_PATH does not contain an exact SHA-256 entry for $ISO_BASE" >&2
  exit 1
fi

if [[ $MATCH_COUNT -gt 1 ]]; then
  echo "[verify-iso] ERROR: $SHA256_PATH contains multiple SHA-256 entries for $ISO_BASE" >&2
  exit 1
fi

ACTUAL_SHA256=$(sha256sum "$ISO_PATH" | awk '{print tolower($1)}')
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "[verify-iso] ERROR: SHA-256 mismatch for $ISO_BASE (expected $EXPECTED_SHA256, got $ACTUAL_SHA256)" >&2
  exit 1
fi

echo "[verify-iso] OK: $ISO_BASE ($ACTUAL_SHA256)"

if [[ -z "$MANIFEST_PATH" ]]; then
  echo "[verify-iso] ERROR: Manifest path is required (--manifest or MANIFEST_PATH)" >&2
  usage
  exit 1
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "[verify-iso] ERROR: Manifest file not found: $MANIFEST_PATH" >&2
  exit 1
fi

echo "[verify-iso] Validating JSON syntax of $MANIFEST_PATH"
python3 -m json.tool "$MANIFEST_PATH" >/dev/null

echo "[verify-iso] All verification checks passed."
