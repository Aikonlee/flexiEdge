#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[02-build-rootfs] Please run as root (sudo)." >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$ROOT_DIR/.work"
ROOTFS="$WORK_DIR/target-rootfs"
OUT_SQUASHFS="$WORK_DIR/target-rootfs.squashfs"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
SUITE="trixie"
VERSION="${FLEXI_VERSION:-6.5.1}"

cleanup_mounts() {
  for fs in run sys proc dev/pts dev; do
    mountpoint -q "$ROOTFS/$fs" && umount -lf "$ROOTFS/$fs" || true
  done
}
trap cleanup_mounts EXIT

# Always rebuild target rootfs and squashfs from scratch
echo "[02-build-rootfs] Removing any previous target rootfs and squashfs..."
cleanup_mounts
rm -rf "$ROOTFS" "$OUT_SQUASHFS"
mkdir -p "$ROOTFS"

echo "[02-build-rootfs] Bootstrapping Debian 13 ($SUITE) target rootfs..."
mkdir -p "$WORK_DIR/debootstrap-cache"
WGETRC_TMP=$(mktemp)
printf 'timeout = 20\ntries = 5\n' > "$WGETRC_TMP"
for attempt in 1 2 3; do
  if WGETRC="$WGETRC_TMP" debootstrap --arch=amd64 --variant=minbase --include=ca-certificates --cache-dir="$WORK_DIR/debootstrap-cache" "$SUITE" "$ROOTFS" "$DEBIAN_MIRROR"; then
    break
  fi
  echo "[02-build-rootfs] debootstrap attempt $attempt failed; retrying..." >&2
  rm -rf "$ROOTFS" && mkdir -p "$ROOTFS"
  [[ $attempt -eq 3 ]] && { rm -f "$WGETRC_TMP"; exit 1; }
done
rm -f "$WGETRC_TMP"

cat <<EOF >"$ROOTFS/etc/apt/sources.list"
deb $DEBIAN_MIRROR $SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR $SUITE-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security $SUITE-security main contrib non-free-firmware
EOF

echo "flexiwan-router" >"$ROOTFS/etc/hostname"
cat <<'EOF' >"$ROOTFS/etc/hosts"
127.0.0.1 localhost
127.0.1.1 flexiwan-router
::1 localhost ip6-localhost ip6-loopback
EOF

for fs in dev dev/pts proc sys run; do
  mount --bind "/$fs" "$ROOTFS/$fs"
done

PACKAGES=$(grep -vE '^\s*(#|$)' "$ROOT_DIR/config/target-packages.list" | tr '\n' ' ')

if [[ -n ${EDGEUI_SOURCE:-} ]]; then
  [[ -f "$EDGEUI_SOURCE/backend/web_service.py" && -f "$EDGEUI_SOURCE/client/index.html" ]] || { echo 'Invalid EDGEUI_SOURCE' >&2; exit 1; }
  PACKAGES+=' python3-cherrypy3 python3-pam systemd-resolved'
fi

PACKAGES="$PACKAGES" chroot "$ROOTFS" /bin/bash -euo pipefail <<'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PACKAGES

# Right-click in a serial terminal must paste, not start Visual mode.
# defaults.vim sets mouse=a after vimrc.local unless this skip is set.
mkdir -p /etc/vim /etc/skel /root
cat > /etc/vim/vimrc.local << 'VIMEOF'
let g:skip_defaults_vim = 1
set mouse=
set ttymouse=
VIMEOF
cp /etc/vim/vimrc.local /etc/skel/.vimrc
cp /etc/vim/vimrc.local /root/.vimrc

# Default admin user (admin / flexiwan)
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo admin
fi
echo 'admin:flexiwan' | chpasswd
passwd -l root || true
if [ -f /etc/skel/.vimrc ]; then
  cp /etc/skel/.vimrc /home/admin/.vimrc
  chown admin:admin /home/admin/.vimrc
fi

# Enable serial console & SSH
systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable serial-getty@ttyS0.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Disable isc-dhcp-server by default (managed dynamically by flexiagent)
systemctl disable isc-dhcp-server || true

# Default Netplan DHCP so appliance gets IP on first boot for flexiEdge Web UI
mkdir -p /etc/netplan
cat <<'NETEOF' >/etc/netplan/01-flexiedge-dhcp.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      optional: true
NETEOF
chmod 0600 /etc/netplan/01-flexiedge-dhcp.yaml

# Kernel forwarding, HugePages & VPP/DPDK modules
cat <<'SYSEOF' >/etc/sysctl.d/99-flexiwan.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
vm.nr_hugepages=1024
vm.max_map_count=3096
SYSEOF

cat <<'MODEOF' >/etc/modules-load.d/flexiwan.conf
vfio-pci
uio_pci_generic
8021q
MODEOF

# GRUB serial + VGA defaults
cat <<'GRUBEOF' >/etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="flexiEdge (Debian 13)"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUBEOF
CHROOT_EOF

# Stage flexiWAN components into /opt/flexiwan/src
echo "[02-build-rootfs] Staging flexiWAN components into target rootfs..."
mkdir -p "$ROOTFS/opt/flexiwan/src" "$ROOTFS/opt/flexiwan/bin" "$ROOTFS/etc/flexiwan/agent" "$ROOTFS/var/log/flexiwan" "$ROOTFS/var/crash"
for repo in flexiEdge flexiagent flexiRouter flexiRouterVPP flexiRouterSB flexiWANCharts; do
  if [[ -d "$WORK_DIR/repos/$repo" ]]; then
    rsync -a --exclude='.git' "$WORK_DIR/repos/$repo/" "$ROOTFS/opt/flexiwan/src/$repo/"
  fi
done
[[ -d "$ROOTFS/opt/flexiwan/src/flexiagent" ]] || { echo "[02-build-rootfs] ERROR: flexiagent missing in target rootfs" >&2; exit 1; }
[[ -f "$WORK_DIR/manifest.json" ]] && cp "$WORK_DIR/manifest.json" "$ROOTFS/etc/flexiwan/build-info.json"

# Install optional pre-built VPP .deb packages if present
if compgen -G "$ROOT_DIR/cache/packages/*.deb" >/dev/null; then
  echo "[02-build-rootfs] Installing cached .deb packages..."
  mkdir -p "$ROOTFS/tmp/debs"
  cp "$ROOT_DIR"/cache/packages/*.deb "$ROOTFS/tmp/debs/"
  chroot "$ROOTFS" /bin/bash -euo pipefail -c "DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/debs/*.deb || apt-get -f install -y"
  rm -rf "$ROOTFS/tmp/debs"
  if ! find "$ROOTFS/usr/share/vpp/api" -name '*.api.json' -print -quit | grep -q .; then
    echo "[02-build-rootfs] ERROR: VPP API JSON was not installed. Refusing to pack a dummy-VPP image." >&2
    exit 1
  fi
  if ! find "$ROOTFS/usr/lib" -type f -path '*/vpp_plugins/router_plugin.so' -print -quit | grep -q .; then
    echo '[02-build-rootfs] ERROR: Missing flexiRouterSB router_plugin.so; TAP injection is required.' >&2
    exit 1
  fi
  chroot "$ROOTFS" /bin/bash -euo pipefail -c "python3 -c 'import vpp_papi; print(vpp_papi.__file__)'"
else
  echo "[02-build-rootfs] ERROR: cache/packages has no VPP .deb files. Production ISO requires them." >&2
  exit 1
fi

# Preserve the physical NIC MAC assigned by the sideband plugin.
install -d "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/05-flexiedge-vpp-tap.link" <<'EOF'
[Match]
Driver=tun
OriginalName=vpp[0-9]*

[Link]
MACAddressPolicy=none
EOF

# Stage VPP default startup.conf and backups if present
if [[ -f "$ROOTFS/opt/flexiwan/src/flexiRouter/scripts/startup.conf" ]]; then
  mkdir -p "$ROOTFS/etc/vpp"
  cp "$ROOTFS/opt/flexiwan/src/flexiRouter/scripts/startup.conf" "$ROOTFS/etc/vpp/startup.conf"
  cp "$ROOTFS/opt/flexiwan/src/flexiRouter/scripts/startup.conf" "$ROOTFS/etc/vpp/startup.conf.baseline"
  cp "$ROOTFS/opt/flexiwan/src/flexiRouter/scripts/startup.conf" "$ROOTFS/etc/vpp/startup.conf.orig"
fi

# Ensure vpp_api.py falls back cleanly at import time to dummy wrapper if /usr/share/vpp/api/*.api.json is absent,
# and ensure fwutils.get_machine_id() falls back to /etc/machine-id when /sys/class/dmi/id/product_uuid is absent
python3 - "$ROOTFS/opt/flexiwan/src/flexiagent" <<'PY'
import os, sys

agent_dir = sys.argv[1]

dummy_path = os.path.join(agent_dir, "vpp_papi_dummy.py")
with open(dummy_path, "r") as f:
    dummy_src = f.read()
if "import logging" not in dummy_src:
    dummy_src = dummy_src.replace("import types\n", "import logging\nimport types\n", 1)
dummy_src = dummy_src.replace(
    "def __init__(self, apifiles, use_socket=False, read_timeout=5):",
    "def __init__(self, apifiles, use_socket=False, read_timeout=5, **kwargs):",
)
if "self.logger =" not in dummy_src:
    dummy_src = dummy_src.replace(
        "self.api = _VPP_API()",
        "self.logger = logging.getLogger('vpp_papi_dummy')\n        self.api = _VPP_API()",
        1,
    )
with open(dummy_path, "w") as f:
    f.write(dummy_src)

vpp_api_path = os.path.join(agent_dir, "vpp_api.py")
with open(vpp_api_path, "r") as f:
    vpp_src = f.read()

old_import = """try:
    from vpp_papi import VPPApiClient
    vppWrapper = False"""

new_import = """def _has_vpp_api_json(vpp_json_dir='/usr/share/vpp/api/'):
    for _, _, filenames in os.walk(vpp_json_dir):
        if fnmatch.filter(filenames, '*.api.json'):
            return True
    return False

try:
    if not _has_vpp_api_json():
        raise FileNotFoundError("no vpp *.api.json files found in /usr/share/vpp/api/")
    from vpp_papi import VPPApiClient
    vppWrapper = False"""

if old_import not in vpp_src:
    if "_has_vpp_api_json" not in vpp_src:
        raise RuntimeError("Expected VPPApiClient import block not found in vpp_api.py")
else:
    vpp_src = vpp_src.replace(old_import, new_import, 1)

old_syslog = "        self.logger.addHandler(SysLogHandler(address='/dev/log'))"
new_syslog = "        if os.path.exists('/dev/log'):\n            self.logger.addHandler(SysLogHandler(address='/dev/log'))"
if "os.path.exists('/dev/log')" not in vpp_src:
    if old_syslog not in vpp_src:
        raise RuntimeError("Expected SysLogHandler line not found in vpp_api.py")
    vpp_src = vpp_src.replace(old_syslog, new_syslog, 1)

with open(vpp_api_path, "w") as f:
    f.write(vpp_src)

fwutils_path = os.path.join(agent_dir, "fwutils.py")
with open(fwutils_path, "r") as f:
    fwutils_src = f.read()

old_mid = """        else:
            machine_id = subprocess.check_output(['cat','/sys/class/dmi/id/product_uuid']).decode().split('\\n')[0].strip()
        return machine_id.upper()
    except:
        return None"""

new_mid = """        else:
            if os.path.exists('/sys/class/dmi/id/product_uuid'):
                machine_id = subprocess.check_output(['cat','/sys/class/dmi/id/product_uuid']).decode().split('\\n')[0].strip()
            else:
                import uuid as _uuid
                with open('/etc/machine-id', 'r') as _mf:
                    machine_id = str(_uuid.UUID(_mf.read().strip()))
        return machine_id.upper()
    except:
        try:
            import uuid as _uuid
            with open('/etc/machine-id', 'r') as _mf:
                return str(_uuid.UUID(_mf.read().strip())).upper()
        except:
            return None"""

if old_mid not in fwutils_src:
    if "/etc/machine-id" not in fwutils_src:
        raise RuntimeError("Expected get_machine_id block not found in fwutils.py")
else:
    fwutils_src = fwutils_src.replace(old_mid, new_mid, 1)

with open(fwutils_path, "w") as f:
    f.write(fwutils_src)

print("[02-build-rootfs] Patched vpp_api.py, vpp_papi_dummy.py, and fwutils.py cleanly.")
PY

# Setup flexiagent config, empty token.txt, versions metadata, and CLI wrappers
AGENT_CONFIG="$ROOTFS/etc/flexiwan/agent/fwagent_conf.yaml"
cp "$ROOTFS/opt/flexiwan/src/flexiagent/fwagent_conf.yaml" "$AGENT_CONFIG"
python3 - "$AGENT_CONFIG" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
sections = list(re.finditer(r"(?m)^agent:[ \t]*(?:#[^\n]*)?\n((?:[ \t]+[^\n]*\n?|\n)*)", source))
if len(sections) != 1:
    sys.exit("Expected exactly one agent configuration section")
section = sections[0]
body, count = re.subn(r"(?m)^  server:[^\n]*", '  server: "https://manage.miwide.com:3443"', section[1])
if count != 1:
    sys.exit("Expected exactly one agent.server setting")
path.write_text(source[:section.start(1)] + body + source[section.end(1):], encoding="utf-8")
PY

cat <<EOF >"$ROOTFS/etc/flexiwan/agent/.versions.yaml"
device: ${VERSION}
components:
  router:
    version: ${VERSION}
  agent:
    version: ${VERSION}
  vpp:
    version: 23.02
  frr:
    version: 10.3
EOF

# Leave token.txt strictly empty; never fabricate a management token
: >"$ROOTFS/etc/flexiwan/agent/token.txt"
chmod 0600 "$ROOTFS/etc/flexiwan/agent/token.txt"

cat <<'EOF' >"$ROOTFS/opt/flexiwan/bin/flexiwan-agent"
#!/usr/bin/env bash
set -euo pipefail
source /opt/flexiwan/venv/bin/activate
export PYTHONPATH="/opt/flexiwan/src/flexiagent:/opt/flexiwan/src"
exec /opt/flexiwan/venv/bin/python /opt/flexiwan/src/flexiagent/fwagent.py daemon
EOF
chmod 0755 "$ROOTFS/opt/flexiwan/bin/flexiwan-agent"
ln -sf /opt/flexiwan/bin/flexiwan-agent "$ROOTFS/usr/local/bin/flexiwan-agent"

cat <<'EOF' >"$ROOTFS/usr/local/bin/fwagent"
#!/usr/bin/env bash
set -euo pipefail
source /opt/flexiwan/venv/bin/activate
export PYTHONPATH="/opt/flexiwan/src/flexiagent:/opt/flexiwan/src"
exec /opt/flexiwan/venv/bin/python /opt/flexiwan/src/flexiagent/fwagent.py "$@"
EOF
chmod 0755 "$ROOTFS/usr/local/bin/fwagent"
cat <<'EOF' >"$ROOTFS/usr/sbin/dpdk-devbind"
#!/bin/sh
exec /usr/bin/python3 /opt/flexiwan/src/flexiagent/dpdk-devbind.py "$@"
EOF
chmod 0755 "$ROOTFS/usr/sbin/dpdk-devbind"

cat <<'EOF' >"$ROOTFS/usr/local/bin/fwsystem_checker"
#!/usr/bin/env bash
set -euo pipefail
source /opt/flexiwan/venv/bin/activate
export PYTHONPATH="/opt/flexiwan/src/flexiagent:/opt/flexiwan/src"
exec /opt/flexiwan/venv/bin/python /opt/flexiwan/src/flexiagent/tools/system_checker/fwsystem_checker.py "$@"
EOF
chmod 0755 "$ROOTFS/usr/local/bin/fwsystem_checker"

install -m 0644 "$ROOT_DIR/config/systemd/flexiwan-agent.service" "$ROOTFS/etc/systemd/system/flexiwan-router.service"
ln -sfn flexiwan-router.service "$ROOTFS/etc/systemd/system/flexiwan-agent.service"

echo "[02-build-rootfs] Creating /opt/flexiwan/venv and installing Python dependencies (strict)..."
chroot "$ROOTFS" /bin/bash -euo pipefail <<'CHROOT_VENV_EOF'
rm -rf /opt/flexiwan/venv
python3 -m venv --system-site-packages /opt/flexiwan/venv
/opt/flexiwan/venv/bin/python -c 'import vpp_papi; print("CHROOT_VPP_PAPI:", vpp_papi.__file__)'

echo "[02-build-rootfs] Verifying Python imports inside chroot /opt/flexiwan/venv..."
/opt/flexiwan/venv/bin/python -c '
import yaml, jwt, Pyro4, psutil, netaddr, sqlitedict, websocket, pyroute2, argcomplete, getmac, serial, ruamel.yaml, distro, requests
print("CHROOT_PY_IMPORTS_OK:", yaml.__file__)
'
PYTHONPATH="/opt/flexiwan/src/flexiagent:/opt/flexiwan/src" /opt/flexiwan/venv/bin/python /opt/flexiwan/src/flexiagent/fwagent.py version
echo "CHROOT_FWAGENT_VERSION_OK"

systemctl enable flexiwan-router.service
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
truncate -s 0 /etc/machine-id
CHROOT_VENV_EOF

if [[ -n ${EDGEUI_SOURCE:-} ]]; then
  bash "$ROOT_DIR/scripts/install-edgeui.sh" "$ROOTFS" "$EDGEUI_SOURCE"
fi

# The Agent owns vRouter startup and recovery. Do not boot bare VPP.
systemctl --root="$ROOTFS" disable vpp.service
vpp_state=$(systemctl --root="$ROOTFS" is-enabled vpp.service || true)
[[ "$vpp_state" == disabled ]] || { echo "Unexpected VPP unit state: $vpp_state" >&2; exit 1; }
systemctl --root="$ROOTFS" is-enabled --quiet flexiwan-router.service

cleanup_mounts

ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

echo "[02-build-rootfs] Packing $OUT_SQUASHFS..."
rm -f "$OUT_SQUASHFS"
mksquashfs "$ROOTFS" "$OUT_SQUASHFS" -comp xz -e boot/efi
echo "[02-build-rootfs] Done: $(du -h "$OUT_SQUASHFS" | cut -f1)"
