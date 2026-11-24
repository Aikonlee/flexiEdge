#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$ROOT_DIR/.work"
STAGING_DIR="$WORK_DIR/staging"
REF_CHECKOUT_DIR="$WORK_DIR/ref-checkout"
SEED_DIR="$STAGING_DIR/nocloud"
DIST_DIR="$ROOT_DIR/dist"
CONFIG_DIR="$ROOT_DIR/config"
BUNDLE_DIR="$SEED_DIR/repos"

UBUNTU_URL_DEFAULT="https://releases.ubuntu.com/20.04.6/ubuntu-20.04.6-live-server-amd64.iso"
FLEXIEDGE_VERSION_DEFAULT="6.6.0"
FLEXIAGENT_REF_DEFAULT="v6.6.0"
ISO_LABEL_DEFAULT="FLEXIEDGE"

usage() {
  cat <<'EOF'
Usage: scripts/build_iso.sh [options]

Options:
  --ubuntu-url URL        Override base Ubuntu live server ISO URL.
  --flexiwan-version VER  Version string used for artefact naming (default: 6.6.0).
  --flexiagent-ref REF    Pinned git tag/ref for flexiagent (default: v6.6.0; env: FLEXIAGENT_REF).
  --output FILE           Override output ISO path (default: dist/flexiEdge.focal.<VER>.iso).
  --skip-cache            Do not embed offline package cache even if available.
  --keep-workdir          Do not remove staging directory after build (for debugging).
  -h, --help              Show this help.
EOF
}

UBUNTU_URL="$UBUNTU_URL_DEFAULT"
FLEXI_VERSION="$FLEXIEDGE_VERSION_DEFAULT"
FLEXIAGENT_REF="${FLEXIAGENT_REF:-$FLEXIAGENT_REF_DEFAULT}"
OUTPUT=""
SKIP_CACHE=0
KEEP_WORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ubuntu-url)
      UBUNTU_URL="$2"; shift 2;;
    --ubuntu-url=*)
      UBUNTU_URL="${1#*=}"; shift;;
    --flexiwan-version)
      FLEXI_VERSION="$2"; shift 2;;
    --flexiwan-version=*)
      FLEXI_VERSION="${1#*=}"; shift;;
    --flexiagent-ref)
      FLEXIAGENT_REF="$2"; shift 2;;
    --flexiagent-ref=*)
      FLEXIAGENT_REF="${1#*=}"; shift;;
    --output)
      OUTPUT="$2"; shift 2;;
    --output=*)
      OUTPUT="${1#*=}"; shift;;
    --skip-cache)
      SKIP_CACHE=1; shift;;
    --keep-workdir)
      KEEP_WORK=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1;;
  esac
done

# Upstream flexiWAN repositories live on GitLab; our maintained mirrors are on GitHub.
# Confirmed pins (see docs/baseline-6.5.x.md): flexiagent ($FLEXIAGENT_REF, default v6.6.0),
# flexirouter (v21.01.03), flexiroutervpp (v26.02-rc0), and flexiroutersb (v21.01.02.09.13-rc0).
# flexiwancharts remains unpinned (TBD).
declare -a REPO_SOURCES=(
  "flexiagent|https://github.com/Aikonlee/flexiagent.git|$FLEXIAGENT_REF"
  "flexirouter|https://github.com/Aikonlee/flexirouter.git|v21.01.03"
  "flexiroutervpp|https://github.com/Aikonlee/flexiroutervpp.git|v26.02-rc0"
  "flexiroutersb|https://github.com/Aikonlee/flexiroutersb.git|v21.01.02.09.13-rc0"
  "flexiwancharts|https://github.com/Aikonlee/flexiwancharts.git|"
)

[[ -n "$OUTPUT" ]] || OUTPUT="$DIST_DIR/flexiEdge.focal.$FLEXI_VERSION.iso"

mkdir -p "$WORK_DIR" "$DIST_DIR"

BASE_ISO="$WORK_DIR/base.iso"
if [[ ! -f "$BASE_ISO" ]]; then
  echo "[build_iso] Downloading Ubuntu base image from $UBUNTU_URL"
  wget -O "$BASE_ISO.part" "$UBUNTU_URL"
  mv "$BASE_ISO.part" "$BASE_ISO"
else
  echo "[build_iso] Using cached Ubuntu ISO at $BASE_ISO"
fi

rm -rf "$STAGING_DIR" "$REF_CHECKOUT_DIR"
mkdir -p "$STAGING_DIR"

echo "[build_iso] Extracting ISO"
xorriso -osirrox on -indev "$BASE_ISO" -extract / "$STAGING_DIR" >/dev/null

mkdir -p "$SEED_DIR"
cp "$CONFIG_DIR/autoinstall/user-data" "$SEED_DIR/user-data"
cp "$CONFIG_DIR/autoinstall/meta-data" "$SEED_DIR/meta-data"
install -m 0755 "$CONFIG_DIR/scripts/setup-flexiwan.sh" "$SEED_DIR/setup-flexiwan.sh"
install -m 0755 "$CONFIG_DIR/scripts/recovery-reinstall.sh" "$SEED_DIR/recovery-reinstall.sh"
if [[ -f "$CONFIG_DIR/scripts/motd.txt" ]]; then
  cp "$CONFIG_DIR/scripts/motd.txt" "$SEED_DIR/motd.txt"
fi

# Copy optional offline packages if they exist and caching is enabled.
if [[ $SKIP_CACHE -eq 0 ]]; then
  if [[ -d "$ROOT_DIR/cache/packages" ]]; then
    mkdir -p "$SEED_DIR/packages"
    cp "$ROOT_DIR"/cache/packages/*.deb "$SEED_DIR/packages" 2>/dev/null || true
  fi
fi

bundle_repo_snapshot() {
  local name="$1"
  local url="$2"
  local ref="${3:-}"
  local source_dir="$ROOT_DIR/$name"
  local archive="$BUNDLE_DIR/${name}.tar.gz"
  local archive_name=""
  local commit=""
  local remote_url="$url"

  mkdir -p "$BUNDLE_DIR"

  if [[ -e "$source_dir/.git" ]]; then
    if [[ -n "$ref" ]]; then
      if ! command -v git >/dev/null 2>&1; then
        echo "[build_iso] ERROR: git is required to archive pinned ref '$ref' for '$name'" >&2
        exit 1
      fi
      remote_url=$(git -C "$source_dir" remote get-url origin 2>/dev/null || echo "$url")
      if ! git -C "$source_dir" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
        echo "[build_iso] Ref '$ref' not found locally in '$name'; fetching tag from origin without modifying working tree"
        if ! git -C "$source_dir" fetch --no-tags origin "refs/tags/${ref}:refs/tags/${ref}"; then
          git -C "$source_dir" fetch --tags origin
        fi
      fi
      if ! commit=$(git -C "$source_dir" rev-parse --verify --quiet "${ref}^{commit}"); then
        echo "[build_iso] ERROR: Unable to resolve pinned ref '$ref' in '$source_dir'" >&2
        exit 1
      fi
      echo "[build_iso] Archiving local repository '$name' at pinned ref '$ref' (commit $commit)"
      git -C "$source_dir" archive --format=tar.gz --output="${archive}.tmp" "$ref"
      mv "${archive}.tmp" "$archive"
      archive_name="$(basename "$archive")"
    else
      if command -v git >/dev/null 2>&1; then
        commit=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)
        remote_url=$(git -C "$source_dir" remote get-url origin 2>/dev/null || echo "$url")
      else
        echo "[build_iso] git not found; omitting metadata for '$name'"
      fi
      echo "[build_iso] Bundling local repository '$name' (unpinned/TBD, commit ${commit:-unknown})"
      tar -czf "${archive}.tmp" --exclude .git --exclude .github --exclude .gitlab --exclude .mypy_cache \
        -C "$source_dir" .
      mv "${archive}.tmp" "$archive"
      archive_name="$(basename "$archive")"
    fi
  elif [[ -n "$ref" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      echo "[build_iso] ERROR: git is required to fetch pinned ref '$ref' for '$name'" >&2
      exit 1
    fi
    local checkout_dir="$REF_CHECKOUT_DIR/$name"
    rm -rf "$checkout_dir"
    mkdir -p "$REF_CHECKOUT_DIR"
    echo "[build_iso] No local git metadata for '$name'; fetching shallow checkout of pinned ref '$ref' from $url"
    if ! git clone --depth 1 --branch "$ref" "$url" "$checkout_dir"; then
      rm -rf "$checkout_dir"
      if [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        echo "[build_iso] Ref '$ref' appears to be a commit SHA; attempting direct shallow fetch"
        mkdir -p "$checkout_dir"
        if ! ( git -C "$checkout_dir" init -q \
          && git -C "$checkout_dir" remote add origin "$url" \
          && git -C "$checkout_dir" fetch --depth 1 origin "$ref" \
          && git -C "$checkout_dir" checkout --detach FETCH_HEAD ); then
          rm -rf "$checkout_dir"
          echo "[build_iso] ERROR: Failed to fetch pinned ref '$ref' for '$name' from '$url'" >&2
          exit 1
        fi
      else
        echo "[build_iso] ERROR: Failed to fetch pinned ref '$ref' for '$name' from '$url'" >&2
        exit 1
      fi
    fi
    if ! commit=$(git -C "$checkout_dir" rev-parse --verify --quiet "HEAD^{commit}"); then
      rm -rf "$checkout_dir"
      echo "[build_iso] ERROR: Unable to resolve commit for pinned ref '$ref' in temporary checkout '$checkout_dir'" >&2
      exit 1
    fi
    echo "[build_iso] Archiving temporary checkout '$name' at pinned ref '$ref' (commit $commit)"
    git -C "$checkout_dir" archive --format=tar.gz --output="${archive}.tmp" HEAD
    mv "${archive}.tmp" "$archive"
    archive_name="$(basename "$archive")"
  else
    echo "[build_iso] No local git checkout for '$name'; embedding remote reference"
    rm -f "$archive"
  fi

  cat <<EOF >>"$BUNDLE_DIR/manifest.tmp"
{ "name": "$name", "ref": "${ref}", "commit": "${commit:-}", "archive": "${archive_name}", "remote": "$remote_url" }
EOF
}

generate_manifest() {
  local manifest="$BUNDLE_DIR/manifest.json"
  if [[ ! -f "$BUNDLE_DIR/manifest.tmp" ]]; then
    return
  fi

  echo "[build_iso] Writing repository manifest"
  {
    echo "{"
    echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"flexiedge_version\": \"$FLEXI_VERSION\","
    echo "  \"flexiagent_ref\": \"$FLEXIAGENT_REF\","
    echo "  \"ubuntu_base_url\": \"$UBUNTU_URL\","
    echo "  \"repositories\": ["
    local first=1
    while IFS= read -r line; do
      if [[ $first -eq 0 ]]; then
        echo "    ,$line"
      else
        echo "    $line"
        first=0
      fi
    done <"$BUNDLE_DIR/manifest.tmp"
    echo "  ]"
    echo "}"
  } >"$manifest"
  rm -f "$BUNDLE_DIR/manifest.tmp"
}

mkdir -p "$BUNDLE_DIR"
>"$BUNDLE_DIR/manifest.tmp"
for entry in "${REPO_SOURCES[@]}"; do
  IFS='|' read -r name url ref <<<"$entry"
  bundle_repo_snapshot "$name" "$url" "$ref"
done
generate_manifest

if [[ -e "$ROOT_DIR/flexiagent/.git" ]] && command -v git >/dev/null 2>&1 \
  && git -C "$ROOT_DIR/flexiagent" cat-file -e "${FLEXIAGENT_REF}:fwagent_conf.yaml" 2>/dev/null; then
  git -C "$ROOT_DIR/flexiagent" show "${FLEXIAGENT_REF}:fwagent_conf.yaml" >"$SEED_DIR/fwagent_conf.yaml"
  chmod 0644 "$SEED_DIR/fwagent_conf.yaml"
elif [[ -f "$REF_CHECKOUT_DIR/flexiagent/fwagent_conf.yaml" ]]; then
  install -m 0644 "$REF_CHECKOUT_DIR/flexiagent/fwagent_conf.yaml" "$SEED_DIR/fwagent_conf.yaml"
elif [[ -f "$ROOT_DIR/flexiagent/fwagent_conf.yaml" ]]; then
  install -m 0644 "$ROOT_DIR/flexiagent/fwagent_conf.yaml" "$SEED_DIR/fwagent_conf.yaml"
fi

append_menu_entry() {
  local file="$1"
  local marker="Install flexiWAN router (UEFI)"
  if grep -q "$marker" "$file"; then
    echo "[build_iso] GRUB already patched: $(realpath --relative-to="$STAGING_DIR" "$file")"
    return
  fi

  cat <<'EOF' >>"$file"

menuentry "Install flexiWAN router (UEFI)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/nocloud/ ip=dhcp quiet splash ---
    initrd  /casper/initrd
}

menuentry "Install flexiWAN router via serial port (UEFI)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/nocloud/ ip=dhcp console=ttyS0,115200n8 console=tty0 quiet ---
    initrd  /casper/initrd
}
EOF
}

append_menu_entry "$STAGING_DIR/boot/grub/grub.cfg"
append_menu_entry "$STAGING_DIR/boot/grub/loopback.cfg"

# Update md5sum manifest
( cd "$STAGING_DIR" && \
  rm -f md5sum.txt && \
  find . -type f -print0 | \
    sort -z | \
    xargs -0 md5sum > md5sum.txt )

VOLID="$ISO_LABEL_DEFAULT"
OUTPUT_TMP="$OUTPUT.tmp"
rm -f "$OUTPUT_TMP"

echo "[build_iso] Creating new ISO"
xorriso -as mkisofs \
  -r -V "$VOLID" \
  -o "$OUTPUT_TMP" \
  -J -l -iso-level 3 \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -partition_offset 16 \
  -c boot.catalog \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTx64.EFI \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$STAGING_DIR"

mv "$OUTPUT_TMP" "$OUTPUT"

SHA_FILE="$OUTPUT.sha256"
( cd "$(dirname "$OUTPUT")" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$SHA_FILE")" )

echo "[build_iso] ISO written to $OUTPUT"

echo "[build_iso] SHA256:"
cat "$SHA_FILE"

if [[ $KEEP_WORK -eq 0 ]]; then
  rm -rf "$STAGING_DIR" "$REF_CHECKOUT_DIR"
fi
