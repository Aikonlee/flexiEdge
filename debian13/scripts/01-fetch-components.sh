#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC_DIR="$ROOT_DIR/.work/repos"
MANIFEST="$ROOT_DIR/.work/manifest.json"
VERSION="${FLEXI_VERSION:-6.5.1}"

mkdir -p "$SRC_DIR"

REPOS=(
  "flexiEdge|https://github.com/Aikonlee/flexiEdge.git"
  "flexiagent|https://github.com/Aikonlee/flexiagent.git"
  "flexiRouter|https://github.com/Aikonlee/flexiRouter.git"
  "flexiRouterVPP|https://github.com/Aikonlee/flexiRouterVPP.git"
  "flexiRouterSB|https://github.com/Aikonlee/flexiRouterSB.git"
  "flexiWANCharts|https://github.com/Aikonlee/flexiWANCharts.git"
)

echo "[01-fetch] Fetching flexiEdge component repositories..."
TMP_ENTRIES=$(mktemp)
trap 'rm -f "$TMP_ENTRIES"' EXIT

for entry in "${REPOS[@]}"; do
  IFS='|' read -r name url <<<"$entry"
  dest="$SRC_DIR/$name"
  pin=
  case "$name" in
    flexiRouterVPP) pin=4c3b404f58f8c95d0617233472079a3e5f4ce782 ;;
    flexiRouterSB) pin=6beeae659fc50cfb1a8ba7c5c2413d59d8b6e073 ;;
  esac
  if [[ -n "$pin" ]]; then
    if [[ ! -d "$dest/.git" ]]; then git init "$dest"; fi
    if ! git -C "$dest" cat-file -e "$pin^{commit}" 2>/dev/null; then
      git -C "$dest" fetch --depth 1 "$url" "$pin"
    fi
    git -C "$dest" checkout --detach "$pin"
  elif [[ -d "$dest/.git" ]]; then
    echo "[01-fetch] Updating $name..."
    if git -C "$dest" fetch --depth 1 origin; then
      git -C "$dest" reset --hard origin/HEAD || true
    else
      echo "[01-fetch] WARNING: Failed to refresh $name from remote; keeping local checkout." >&2
    fi
  else
    echo "[01-fetch] Cloning $name ($url)..."
    if ! git clone --depth 1 "$url" "$dest"; then
      echo "[01-fetch] WARNING: Failed to clone $name ($url); continuing without it." >&2
      rm -rf "$dest"
    fi
  fi
  if [[ -d "$dest/.git" ]]; then
    commit=$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "{\"name\":\"$name\",\"remote\":\"$url\",\"commit\":\"$commit\"}" >>"$TMP_ENTRIES"
  else
    echo "{\"name\":\"$name\",\"remote\":\"$url\",\"commit\":\"unavailable\"}" >>"$TMP_ENTRIES"
  fi
done

# flexiagent is strictly required
[[ -d "$SRC_DIR/flexiagent" ]] || { echo "[01-fetch] ERROR: flexiagent repository is missing!" >&2; exit 1; }

python3 - "$VERSION" "$TMP_ENTRIES" "$MANIFEST" <<'PY'
import json, sys, datetime
version, entries_path, out_path = sys.argv[1:4]
repos = [json.loads(line) for line in open(entries_path) if line.strip()]
doc = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "flexiedge_version": version,
    "base_os": "Debian 13 (Trixie)",
    "repositories": repos,
}
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)
PY

echo "[01-fetch] Manifest written to $MANIFEST"
