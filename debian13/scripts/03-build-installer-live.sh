#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[03-build-installer-live] Please run as root (sudo)." >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$ROOT_DIR/.work"
LIVE_ROOTFS="$WORK_DIR/installer-rootfs"
LIVE_OUT="$WORK_DIR/live"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
SUITE="trixie"

cleanup_mounts() {
  for fs in run sys proc dev/pts dev; do
    mountpoint -q "$LIVE_ROOTFS/$fs" && umount -lf "$LIVE_ROOTFS/$fs" || true
  done
}
trap cleanup_mounts EXIT

echo "[03-build-installer-live] Bootstrapping minimal Debian 13 ($SUITE) Live installer..."
rm -rf "$LIVE_ROOTFS" "$LIVE_OUT"
mkdir -p "$LIVE_ROOTFS" "$LIVE_OUT" "$WORK_DIR/debootstrap-cache"

WGETRC_TMP=$(mktemp)
printf 'timeout = 20\ntries = 5\n' > "$WGETRC_TMP"
for attempt in 1 2 3; do
  if WGETRC="$WGETRC_TMP" debootstrap --arch=amd64 --variant=minbase --include=ca-certificates --cache-dir="$WORK_DIR/debootstrap-cache" "$SUITE" "$LIVE_ROOTFS" "$DEBIAN_MIRROR"; then
    break
  fi
  echo "[03-build-installer-live] debootstrap attempt $attempt failed; retrying..." >&2
  rm -rf "$LIVE_ROOTFS" && mkdir -p "$LIVE_ROOTFS"
  [[ $attempt -eq 3 ]] && { rm -f "$WGETRC_TMP"; exit 1; }
done
rm -f "$WGETRC_TMP"

for fs in dev dev/pts proc sys run; do
  mount --bind "/$fs" "$LIVE_ROOTFS/$fs"
done

chroot "$LIVE_ROOTFS" /bin/bash -euo pipefail -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    whiptail \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    squashfs-tools \
    util-linux \
    udev \
    kmod \
    procps \
    kbd
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"

# Copy TUI installer, recovery helper, and EULA
mkdir -p "$LIVE_ROOTFS/etc/flexiwan-installer"
install -m 0755 "$ROOT_DIR/installer/flexiwan-installer.sh" "$LIVE_ROOTFS/usr/local/sbin/flexiwan-installer.sh"
install -m 0755 "$ROOT_DIR/installer/recovery-reinstall.sh" "$LIVE_ROOTFS/usr/local/sbin/recovery-reinstall.sh"
install -m 0644 "$ROOT_DIR/config/eula.txt" "$LIVE_ROOTFS/etc/flexiwan-installer/eula.txt"

# Auto-launch installer on tty1 (VGA) or ttyS0 (Serial) depending on kernel cmdline
cat <<'EOF' >"$LIVE_ROOTFS/usr/local/sbin/flexiwan-launcher.sh"
#!/usr/bin/env bash
set -euo pipefail
MODE="vga"
if grep -q "flexi_mode=serial" /proc/cmdline 2>/dev/null; then
  MODE="serial"
fi
TTY_DEV=$(tty || echo "unknown")
if [[ "$MODE" == "serial" && "$TTY_DEV" == "/dev/ttyS0" ]]; then
  exec /usr/local/sbin/flexiwan-installer.sh
elif [[ "$MODE" == "vga" && "$TTY_DEV" == "/dev/tty1" ]]; then
  exec /usr/local/sbin/flexiwan-installer.sh
fi
exec /sbin/agetty --autologin root --noclear "${TTY_DEV#/dev/}" linux
EOF
chmod 0755 "$LIVE_ROOTFS/usr/local/sbin/flexiwan-launcher.sh"

mkdir -p "$LIVE_ROOTFS/etc/systemd/system/getty@tty1.service.d" \
         "$LIVE_ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"

cat <<'EOF' >"$LIVE_ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -n -l /usr/local/sbin/flexiwan-launcher.sh --noclear %I $TERM
Type=idle
EOF

cat <<'EOF' >"$LIVE_ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -n -l /usr/local/sbin/flexiwan-launcher.sh --keep-baud 115200,57600,38400,9600 %I vt100
Type=idle
EOF

chroot "$LIVE_ROOTFS" systemctl enable serial-getty@ttyS0.service || true

# Extract kernel and initrd for ISO boot
cp "$LIVE_ROOTFS"/boot/vmlinuz-* "$LIVE_OUT/vmlinuz"
cp "$LIVE_ROOTFS"/boot/initrd.img-* "$LIVE_OUT/initrd.img"

cleanup_mounts

echo "[03-build-installer-live] Packing installer Live squashfs..."
mksquashfs "$LIVE_ROOTFS" "$LIVE_OUT/filesystem.squashfs" -comp xz -e boot
echo "[03-build-installer-live] Done: $(du -h "$LIVE_OUT/filesystem.squashfs" | cut -f1)"
