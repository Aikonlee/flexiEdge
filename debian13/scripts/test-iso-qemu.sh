#!/usr/bin/env bash
set -euo pipefail

ISO_PATH="${1:-}"
DISK_IMG="${2:-/tmp/flexiedge-test-disk.qcow2}"
VARS_IMG="${DISK_IMG%.qcow2}.ovmf-vars.fd"

if [[ -z "$ISO_PATH" || ! -f "$ISO_PATH" ]]; then
  echo "Usage: $0 <path-to-flexiEdge.iso> [disk.qcow2]" >&2
  exit 1
fi

OVMF_CODE=""
OVMF_VARS_SRC=""
for candidate in \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/ovmf/OVMF.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_CODE="$candidate"
    break
  fi
done

for candidate in \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_VARS_SRC="$candidate"
    break
  fi
done

if [[ -z "$OVMF_CODE" ]]; then
  echo "OVMF UEFI firmware not found. Install 'ovmf' package first." >&2
  exit 1
fi

if [[ ! -f "$DISK_IMG" ]]; then
  echo "[qemu-test] Creating 20G virtual disk at $DISK_IMG"
  qemu-img create -f qcow2 "$DISK_IMG" 20G
fi

PFLASH_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE")
if [[ -n "$OVMF_VARS_SRC" ]]; then
  if [[ ! -f "$VARS_IMG" ]]; then
    cp "$OVMF_VARS_SRC" "$VARS_IMG"
  fi
  PFLASH_ARGS+=(-drive "if=pflash,format=raw,file=$VARS_IMG")
fi

KVM_ARGS=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
fi

echo "[qemu-test] Booting ISO in UEFI + Serial mode (Ctrl-A X to exit QEMU)"
echo "[qemu-test] Tip: Select 'Install flexiWAN router via serial port (UEFI)' in GRUB"
exec qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -m 4096 \
  -smp 2 \
  "${PFLASH_ARGS[@]}" \
  -drive "file=$DISK_IMG,format=qcow2,if=virtio" \
  -cdrom "$ISO_PATH" \
  -nographic
