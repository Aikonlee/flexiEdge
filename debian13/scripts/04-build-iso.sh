#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$ROOT_DIR/.work"
ISO_STAGE="$WORK_DIR/iso-stage"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${FLEXI_VERSION:-6.5.1}"
ISO_LABEL="FLEXIEDGE"
OUTPUT="${1:-$DIST_DIR/flexiEdge.trixie.${VERSION}.iso}"

[[ -f "$WORK_DIR/live/vmlinuz" ]] || { echo "Missing $WORK_DIR/live/vmlinuz (run 03-build-installer-live.sh first)"; exit 1; }
[[ -f "$WORK_DIR/target-rootfs.squashfs" ]] || { echo "Missing $WORK_DIR/target-rootfs.squashfs (run 02-build-rootfs.sh first)"; exit 1; }

rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE/live" "$ISO_STAGE/flexi" "$ISO_STAGE/boot/grub" "$ISO_STAGE/EFI/BOOT" "$DIST_DIR"

cp "$WORK_DIR/live/vmlinuz" "$ISO_STAGE/live/vmlinuz"
cp "$WORK_DIR/live/initrd.img" "$ISO_STAGE/live/initrd.img"
cp "$WORK_DIR/live/filesystem.squashfs" "$ISO_STAGE/live/filesystem.squashfs"
cp "$WORK_DIR/target-rootfs.squashfs" "$ISO_STAGE/flexi/target-rootfs.squashfs"
[[ -f "$WORK_DIR/manifest.json" ]] && cp "$WORK_DIR/manifest.json" "$ISO_STAGE/flexi/manifest.json"
cp "$ROOT_DIR/installer/grub/iso-grub.cfg" "$ISO_STAGE/boot/grub/grub.cfg"

echo "[04-build-iso] Building standalone UEFI GRUB binary..."
grub-mkstandalone \
  --format=x86_64-efi \
  --output="$ISO_STAGE/EFI/BOOT/BOOTX64.EFI" \
  --locales="" \
  --fonts="" \
  "boot/grub/grub.cfg=$ISO_STAGE/boot/grub/grub.cfg"

echo "[04-build-iso] Creating FAT EFI boot image (efiboot.img)..."
EFI_IMG="$WORK_DIR/efiboot.img"
rm -f "$EFI_IMG"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none
mkfs.fat -F 12 -n "EFIBOOT" "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$ISO_STAGE/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$EFI_IMG" "$ISO_STAGE/boot/grub/efiboot.img"

echo "[04-build-iso] Packaging UEFI Hybrid ISO (CD-ROM + USB GPT ESP) with xorriso..."
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "$ISO_LABEL" \
  -eltorito-alt-boot \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -append_partition 2 0xef "$EFI_IMG" \
  -appended_part_as_gpt \
  -output "$OUTPUT" \
  "$ISO_STAGE"

( cd "$(dirname "$OUTPUT")" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" )

echo "[04-build-iso] ISO created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
cat "${OUTPUT}.sha256"
