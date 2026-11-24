#!/usr/bin/env bash
set -euo pipefail

TITLE="flexiWAN Setup"
MEDIA_ROOT="/run/live/medium"
TARGET_SQUASHFS="${MEDIA_ROOT}/flexi/target-rootfs.squashfs"
EULA_FILE="/etc/flexiwan-installer/eula.txt"
LOG_FILE="/tmp/flexiwan-install.log"
UNATTENDED=0

for arg in "$@"; do
  case "$arg" in
    --unattended) UNATTENDED=1 ;;
  esac
done

if grep -q "flexi_unattended=1" /proc/cmdline 2>/dev/null; then
  UNATTENDED=1
fi

export TERM="${TERM:-vt100}"
# Hide kernel/console chatter under the installer dialogs.
dmesg -n 1 2>/dev/null || true
printf '\033[2J\033[H' >/dev/tty 2>/dev/null || true

log() {
  # File only. tee to the console paints a status line under the whiptail screen.
  echo "[$(date -u +%H:%M:%S)] $*" >>"$LOG_FILE"
}

die() {
  log "ERROR: $*"
  if [[ $UNATTENDED -eq 0 ]]; then
    whiptail --title "$TITLE" --msgbox "Installation failed:\n\n$*\n\nSee $LOG_FILE for details." 14 70 || true
  fi
  exit 1
}

detect_disks() {
  # Ensure udev has populated all block devices (virtio, nvme, scsi)
  udevadm settle --timeout=10 2>/dev/null || true

  # Exclude loop, ram, sr (cdrom), fd, and the disk backing /run/live/medium
  local live_src live_skip
  live_src=$(findmnt -n -o SOURCE "$MEDIA_ROOT" 2>/dev/null || true)
  live_skip=""
  if [[ -n "$live_src" ]]; then
    live_skip=$(lsblk -no PKNAME "$live_src" 2>/dev/null | head -n1 || true)
    if [[ -z "$live_skip" ]]; then
      live_skip=$(lsblk -no NAME "$live_src" 2>/dev/null | head -n1 || true)
    fi
  fi

  local line NAME SIZE MODEL TYPE
  while IFS= read -r line; do
    NAME="" SIZE="" MODEL="" TYPE=""
    eval "$line"
    [[ "$TYPE" == "disk" ]] || continue
    [[ -n "$live_skip" && "$NAME" == "$live_skip" ]] && continue
    [[ "$NAME" =~ ^(loop|ram|zram|sr|fd) ]] && continue
    [[ -z "$MODEL" ]] && MODEL="Disk"
    printf '/dev/%s|%s (%s)\n' "$NAME" "$SIZE" "$MODEL"
  done < <(lsblk -dnP -o NAME,SIZE,MODEL,TYPE)
}

extract_with_gauge() {
  local src="$1" dest="$2"
  local total_kb used_kb pct pid
  # unsquashfs -s prints "Filesystem size <bytes> bytes (<kb> Kbytes / ...)".
  # Taking field 3 compares du's KB against the byte count, so the gauge stays 0
  # until the forced 100 at exit.
  total_kb=$(unsquashfs -s "$src" | sed -n 's/.*(\([0-9.]*\) Kbytes.*/\1/p' | head -n1 | cut -d. -f1)
  [[ -n "$total_kb" && "$total_kb" -gt 0 ]] || total_kb=1
  unsquashfs -f -d "$dest" "$src" >>"$LOG_FILE" 2>&1 &
  pid=$!
  # stdbuf -oL: a pipe fully-buffers the subshell, so whiptail would only see 100.
  stdbuf -oL bash -c '
    dest="$1"; total_kb="$2"; pid="$3"
    while kill -0 "$pid" 2>/dev/null; do
      used_kb=$(du -sk "$dest" 2>/dev/null | awk "{print \$1}")
      used_kb=${used_kb:-0}
      pct=$(( used_kb * 100 / total_kb ))
      if (( pct > 99 )); then pct=99; fi
      printf "%s\n" "$pct"
      sleep 1
    done
    printf "100\n"
  ' _ "$dest" "$total_kb" "$pid" \
    | whiptail --title "flexiWAN Installer" --gauge "Extracting flexiWAN File System" 8 70 0
  wait "$pid"
}

part_path() {
  local disk="$1"
  local num="$2"
  if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

[[ -f "$TARGET_SQUASHFS" ]] || die "Target rootfs image not found at $TARGET_SQUASHFS"

# Step 1: Welcome (guide screenshot: title "flexiWAN Setup", <OK>)
if [[ $UNATTENDED -eq 0 ]]; then
  whiptail --title "flexiWAN Setup" --msgbox \
    "Welcome to flexiWAN Router Install Wizard\n\nThis wizard will guide you through the installation of flexiWAN Router." \
    10 74
fi

# Step 2: EULA (guide screenshot: title, <I Agree> / <Cancel>, scroll percent)
if [[ $UNATTENDED -eq 0 ]]; then
  EULA_TEXT="The flexiWAN End User License Agreement was not found."
  if [[ -f "$EULA_FILE" ]]; then
    EULA_TEXT=$(cat "$EULA_FILE")
  fi
  whiptail --title "FLEXIWAN END USER LICENSE AGREEMENT" \
    --yes-button "I Agree" --no-button "Cancel" \
    --yesno --scrolltext "$EULA_TEXT" 18 76 \
    || die "EULA was not accepted."
fi

# Step 3: Auto-detect disk
mapfile -t DISKS < <(detect_disks)
[[ ${#DISKS[@]} -gt 0 ]] || die "No suitable target hard drive detected."

TARGET_DISK=""
if [[ $UNATTENDED -eq 1 ]]; then
  TARGET_DISK="${DISKS[0]%%|*}"
else
  MENU_ARGS=()
  for entry in "${DISKS[@]}"; do
    MENU_ARGS+=("${entry%%|*}" "${entry#*|}")
  done
  TARGET_DISK=$(whiptail --title "$TITLE - Select Target Disk" \
    --menu "Select the target drive. ALL DATA ON THE SELECTED DRIVE WILL BE ERASED:" 16 74 8 \
    "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || die "Installation cancelled by user."
  whiptail --title "flexiWAN WARNING" \
    --yes-button "OK" --no-button "Cancel" --yesno \
    "WARNING: ALL DATA ON THE DEVICE WILL BE DESTROYED. TO CONTINUE WITH THE OPERATION, CLICK OK. TO QUIT CLICK CANCEL." \
    10 74 || die "Installation cancelled by user."
fi

log "Selected target disk: $TARGET_DISK"

# Step 4: Partitioning (GPT: p1 EFI 512M, p2 Main Root, p3 Recovery 4G)
log "Wiping and partitioning $TARGET_DISK..."
wipefs -af "$TARGET_DISK" >>"$LOG_FILE" 2>&1 || true
sgdisk --zap-all "$TARGET_DISK" >>"$LOG_FILE" 2>&1

DISK_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
# Use 4GiB recovery partition if disk >= 12GiB, else 2GiB
RECOVERY_SIZE="4G"
if (( DISK_BYTES < 12 * 1024 * 1024 * 1024 )); then
  RECOVERY_SIZE="2G"
fi

sgdisk -n 1:2048:+512M -t 1:EF00 -c 1:"EFI" "$TARGET_DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 3:-"${RECOVERY_SIZE}":0 -t 3:8300 -c 3:"FLEXI_RECOVERY" "$TARGET_DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 2:0:0 -t 2:8300 -c 2:"FLEXI_ROOT" "$TARGET_DISK" >>"$LOG_FILE" 2>&1
partprobe "$TARGET_DISK" >>"$LOG_FILE" 2>&1 || true
udevadm settle --timeout=10 2>/dev/null || true
sleep 2

P_EFI=$(part_path "$TARGET_DISK" 1)
P_ROOT=$(part_path "$TARGET_DISK" 2)
P_REC=$(part_path "$TARGET_DISK" 3)

log "Formatting partitions: EFI=$P_EFI ROOT=$P_ROOT RECOVERY=$P_REC"
mkfs.fat -F 32 -n EFI "$P_EFI" >>"$LOG_FILE" 2>&1
mkfs.ext4 -F -L FLEXI_ROOT "$P_ROOT" >>"$LOG_FILE" 2>&1
mkfs.ext4 -F -L FLEXI_RECOVERY "$P_REC" >>"$LOG_FILE" 2>&1

# Step 5: Deploy target rootfs & recovery partition
mkdir -p /mnt/target /mnt/recovery
mount "$P_ROOT" /mnt/target
mkdir -p /mnt/target/boot/efi /mnt/target/recovery
mount "$P_EFI" /mnt/target/boot/efi
mount "$P_REC" /mnt/recovery

log "Extracting target rootfs ($TARGET_SQUASHFS) to $P_ROOT..."
if [[ $UNATTENDED -eq 0 ]]; then
  extract_with_gauge "$TARGET_SQUASHFS" /mnt/target
else
  unsquashfs -f -d /mnt/target "$TARGET_SQUASHFS" >>"$LOG_FILE" 2>&1
fi

log "Populating recovery partition ($P_REC)..."
mkdir -p /mnt/recovery/flexi /mnt/recovery/live
cp "$TARGET_SQUASHFS" /mnt/recovery/flexi/target-rootfs.squashfs
cp "${MEDIA_ROOT}/live/vmlinuz" /mnt/recovery/live/vmlinuz
cp "${MEDIA_ROOT}/live/initrd.img" /mnt/recovery/live/initrd.img
cp "${MEDIA_ROOT}/live/filesystem.squashfs" /mnt/recovery/live/filesystem.squashfs
if [[ -f /usr/local/sbin/recovery-reinstall.sh ]]; then
  install -m 0755 /usr/local/sbin/recovery-reinstall.sh /mnt/recovery/recovery-reinstall.sh
fi

# Step 6: Generate /etc/fstab & install UEFI GRUB
UUID_EFI=$(blkid -s UUID -o value "$P_EFI")
UUID_ROOT=$(blkid -s UUID -o value "$P_ROOT")
UUID_REC=$(blkid -s UUID -o value "$P_REC")

cat <<EOF >/mnt/target/etc/fstab
UUID=${UUID_ROOT}  /          ext4  errors=remount-ro  0  1
UUID=${UUID_EFI}   /boot/efi  vfat  umask=0077         0  2
UUID=${UUID_REC}   /recovery  ext4  ro,noauto,nofail   0  2
EOF

# Add GRUB recovery menu entry on target system
cat <<EOF >/mnt/target/etc/grub.d/40_flexiwan_recovery
#!/bin/sh
exec tail -n +3 \$0
menuentry "flexiWAN Recovery (Offline Reinstall)" {
    search --no-floppy --fs-uuid --set=root ${UUID_REC}
    linux  /live/vmlinuz boot=live components live-media-path=/live console=tty0 console=ttyS0,115200n8
    initrd /live/initrd.img
}
EOF
chmod 0755 /mnt/target/etc/grub.d/40_flexiwan_recovery

# Bind mounts for chroot GRUB installation (including efivars if booted in UEFI)
for fs in dev dev/pts proc sys run; do
  mount --bind "/$fs" "/mnt/target/$fs"
done
if [[ -d /sys/firmware/efi/efivars ]]; then
  mount --bind /sys/firmware/efi/efivars /mnt/target/sys/firmware/efi/efivars 2>/dev/null || true
fi

log "Installing UEFI GRUB bootloader..."
# 1) Register UEFI NVRAM boot entry (so installed OS takes precedence over USB/ISO on reboot)
chroot /mnt/target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=flexiEdge >>"$LOG_FILE" 2>&1 || true
# 2) Always also install fallback /EFI/BOOT/BOOTX64.EFI for systems without persistent NVRAM
chroot /mnt/target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=flexiEdge --removable --no-nvram >>"$LOG_FILE" 2>&1
chroot /mnt/target update-grub >>"$LOG_FILE" 2>&1
chroot /mnt/target dpkg-reconfigure -f noninteractive openssh-server >>"$LOG_FILE" 2>&1 || true

mountpoint -q /mnt/target/sys/firmware/efi/efivars && umount -lf /mnt/target/sys/firmware/efi/efivars || true
for fs in run sys proc dev/pts dev; do
  umount -lf "/mnt/target/$fs" || true
done
umount -lf /mnt/recovery || true
umount -lf /mnt/target/boot/efi || true
umount -lf /mnt/target || true
sync

log "Installation complete. Rebooting."
reboot -f
