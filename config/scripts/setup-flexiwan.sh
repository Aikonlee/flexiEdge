#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[setup-flexiwan] Please run as root." >&2
  exit 1
fi

SCRIPT_SRC=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_SRC")
SEED_ROOT=$(readlink -f "$SCRIPT_DIR")
REPO_BUNDLE="$SEED_ROOT/repos"
MANIFEST_FILE="$REPO_BUNDLE/manifest.json"
MOTD_FILE="$SEED_ROOT/motd.txt"
PACKAGES_DIR="$SEED_ROOT/packages"

CACHE_ROOT="/var/lib/flexiwan/install-cache"
CACHE_SCRIPT="$CACHE_ROOT/setup-flexiwan.sh"
CACHE_REPOS="$CACHE_ROOT/repos"
BUILD_INFO_DEST="/etc/flexiwan/build-info.json"
LOG_DIR="/var/log/flexiwan"
LOG_FILE="$LOG_DIR/install.log"

INSTALL_ROOT="/opt/flexiwan"
SRC_ROOT="$INSTALL_ROOT/src"
BIN_DIR="$INSTALL_ROOT/bin"
VENV_DIR="$INSTALL_ROOT/venv"
ETC_DIR="/etc/flexiwan"
AGENT_ETC_DIR="$ETC_DIR/agent"
TOKEN_FILE="$AGENT_ETC_DIR/token.txt"
AGENT_CONF_SRC="$SEED_ROOT/fwagent_conf.yaml"
AGENT_CONF_DEST="$AGENT_ETC_DIR/fwagent_conf.yaml"

SYSTEMD_UNIT="/etc/systemd/system/flexiwan-agent.service"
WRAPPER_BIN="$BIN_DIR/flexiwan-agent"
PYTHON_BIN="/usr/bin/python3"

# Pinned flexiagent release ref (default v6.6.0); all companion pins are defined in the default
# repository list below and in docs/baseline-6.5.x.md (flexiwancharts is pinned to the newly
# created annotated tag 6.6.0 at commit acc9f21abc1f09792f5a927254004de556f1e1d0; the resolved
# commit SHA is still recorded in manifest.json at build time for audit).
FLEXIAGENT_REF="${FLEXIAGENT_REF:-v6.6.0}"

RECONFIGURE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure)
      RECONFIGURE=1
      shift
      ;;
    --manifest)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --bundle)
      REPO_BUNDLE="$2"
      shift 2
      ;;
    *)
      echo "[setup-flexiwan] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$MANIFEST_FILE" && -f "$CACHE_ROOT/manifest.json" ]]; then
  MANIFEST_FILE="$CACHE_ROOT/manifest.json"
fi

if [[ ! -d "$REPO_BUNDLE" && -d "$CACHE_REPOS" ]]; then
  REPO_BUNDLE="$CACHE_REPOS"
fi

if [[ ! -f "$AGENT_CONF_SRC" && -f "$CACHE_ROOT/fwagent_conf.yaml" ]]; then
  AGENT_CONF_SRC="$CACHE_ROOT/fwagent_conf.yaml"
fi

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[setup-flexiwan] Starting flexiWAN provisioning"

mkdir -p "$CACHE_ROOT" "$CACHE_REPOS" "$INSTALL_ROOT" "$SRC_ROOT" "$BIN_DIR" "$ETC_DIR" "$AGENT_ETC_DIR"

copy_seed_assets() {
  echo "[setup-flexiwan] Caching seed assets under $CACHE_ROOT"
  cp "$SCRIPT_SRC" "$CACHE_SCRIPT"
  chmod 0755 "$CACHE_SCRIPT"
  install -m 0755 "$SCRIPT_SRC" /usr/local/sbin/flexiwan-setup
  if [[ -d "$REPO_BUNDLE" ]]; then
    rsync -a --delete "$REPO_BUNDLE/" "$CACHE_REPOS/"
  fi
  if [[ -f "$MANIFEST_FILE" ]]; then
    install -m 0644 "$MANIFEST_FILE" "$CACHE_ROOT/manifest.json"
    install -m 0644 "$MANIFEST_FILE" "$BUILD_INFO_DEST"
  fi
  if [[ -f "$AGENT_CONF_SRC" ]]; then
    install -m 0644 "$AGENT_CONF_SRC" "$AGENT_ETC_DIR/fwagent_conf.seed.yaml"
    install -m 0644 "$AGENT_CONF_SRC" "$CACHE_ROOT/fwagent_conf.yaml"
  fi
}

install_motd() {
  if [[ -f "$MOTD_FILE" ]]; then
    echo "[setup-flexiwan] Installing custom MOTD"
    install -m 0644 "$MOTD_FILE" /etc/motd
  fi
}

install_packages() {
  local packages=(
    git
    curl
    jq
  net-tools
    ifupdown2
    strongswan
    openvswitch-switch
    lsof
    tcpdump
  rsync
    build-essential
    python3
    python3-pip
    python3-venv
    python3-setuptools
    python3-wheel
    python3-dev
    libffi-dev
    libssl-dev
    pkg-config
  )
  export DEBIAN_FRONTEND=noninteractive
  echo "[setup-flexiwan] Updating package index"
  apt-get update
  echo "[setup-flexiwan] Installing base packages"
  apt-get install -y "${packages[@]}"

  if [[ -d "$PACKAGES_DIR" ]]; then
    echo "[setup-flexiwan] Installing bundled .deb packages"
    dpkg -i "$PACKAGES_DIR"/*.deb || apt-get -f install -y
  fi
}

parse_manifest() {
  local manifest_path="$1"
  if [[ ! -f "$manifest_path" ]]; then
    return
  fi
  python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.exists():
    sys.exit(0)
with path.open() as fh:
    data = json.load(fh)
repos = data.get("repositories", [])
for repo in repos:
    name = repo.get("name", "")
    archive = repo.get("archive", "")
    remote = repo.get("remote", "")
    ref = repo.get("ref", "")
    print(f"{name}|{archive}|{remote}|{ref}")
PY
}

stage_repository() {
  local name="$1"
  local archive="$2"
  local remote="$3"
  local ref="${4:-}"
  local dest="$SRC_ROOT/$name"

  if [[ -z "$ref" && "$name" == "flexiagent" ]]; then
    ref="$FLEXIAGENT_REF"
  fi

  if [[ -n "$archive" && -f "$REPO_BUNDLE/$archive" ]]; then
    echo "[setup-flexiwan] Extracting bundled repo $name${ref:+ (ref $ref)}"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xzf "$REPO_BUNDLE/$archive" -C "$dest" --strip-components=0
  elif [[ -n "$remote" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      echo "[setup-flexiwan] git not available to clone $name; skipping" >&2
      return
    fi
    if [[ -d "$dest/.git" ]]; then
      echo "[setup-flexiwan] Refreshing existing checkout $name${ref:+ (ref $ref)}"
      git -C "$dest" fetch --all --tags
      if [[ -n "$ref" ]]; then
        git -C "$dest" checkout --force "$ref"
      else
        git -C "$dest" reset --hard origin/HEAD 2>/dev/null || true
      fi
    else
      rm -rf "$dest"
      if [[ -n "$ref" ]]; then
        echo "[setup-flexiwan] Cloning $remote at pinned ref $ref"
        if ! git clone --branch "$ref" "$remote" "$dest"; then
          rm -rf "$dest"
          git clone "$remote" "$dest"
          git -C "$dest" checkout --force "$ref"
        fi
      else
        echo "[setup-flexiwan] Cloning $remote (unpinned)"
        git clone "$remote" "$dest"
      fi
    fi
  else
    echo "[setup-flexiwan] No archive or remote for $name"
    return
  fi

  find "$dest" -type d -name '.git' -prune -exec rm -rf {} + 2>/dev/null || true
}

stage_repositories() {
  if [[ -f "$MANIFEST_FILE" ]]; then
    echo "[setup-flexiwan] Staging repositories from manifest"
    while IFS='|' read -r name archive remote ref; do
      [[ -z "$name" ]] && continue
      stage_repository "$name" "$archive" "$remote" "$ref"
    done < <(parse_manifest "$MANIFEST_FILE")
  else
    echo "[setup-flexiwan] No manifest found, attempting default repository list"
    # Upstream flexiWAN repositories live on GitLab; our maintained mirrors are on GitHub.
    # Confirmed pins (see docs/baseline-6.5.x.md): flexiagent (FLEXIAGENT_REF, default v6.6.0),
    # flexirouter (v21.01.03), flexiroutervpp (v26.02-rc0), flexiroutersb (v21.01.02.09.13-rc0),
    # and flexiwancharts (pinned to the newly created annotated tag 6.6.0 at commit
    # acc9f21abc1f09792f5a927254004de556f1e1d0; the resolved commit SHA is still recorded in
    # manifest.json at build time for audit).
    while IFS='|' read -r name url ref; do
      [[ -z "$name" ]] && continue
      stage_repository "$name" "" "$url" "$ref"
    done <<EOF
flexiagent|https://github.com/Aikonlee/flexiagent.git|${FLEXIAGENT_REF}
flexirouter|https://github.com/Aikonlee/flexirouter.git|v21.01.03
flexiroutervpp|https://github.com/Aikonlee/flexiroutervpp.git|v26.02-rc0
flexiroutersb|https://github.com/Aikonlee/flexiroutersb.git|v21.01.02.09.13-rc0
flexiwancharts|https://github.com/Aikonlee/flexiwancharts.git|6.6.0
EOF
  fi
}

setup_python_env() {
  echo "[setup-flexiwan] Preparing Python virtual environment"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
  if [[ -f "$SRC_ROOT/flexiagent/requirements.txt" ]]; then
    "$VENV_DIR/bin/pip" install -r "$SRC_ROOT/flexiagent/requirements.txt"
  else
    echo "[setup-flexiwan] WARNING: flexiagent requirements not found" >&2
  fi
}

install_agent_assets() {
  echo "[setup-flexiwan] Installing agent configuration"
  mkdir -p "$AGENT_ETC_DIR"
  if [[ -f "$AGENT_CONF_SRC" ]]; then
    install -m 0644 "$AGENT_CONF_SRC" "$AGENT_CONF_DEST"
  elif [[ -f "$SRC_ROOT/flexiagent/fwagent_conf.yaml" ]]; then
    install -m 0644 "$SRC_ROOT/flexiagent/fwagent_conf.yaml" "$AGENT_CONF_DEST"
  fi
  touch "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"

  echo "[setup-flexiwan] Creating agent wrapper"
  cat <<EOF >"$WRAPPER_BIN"
#!/usr/bin/env bash
set -euo pipefail
source "$VENV_DIR/bin/activate"
export PYTHONPATH="$SRC_ROOT/flexiagent:$SRC_ROOT"
exec "$VENV_DIR/bin/python" "$SRC_ROOT/flexiagent/fwagent.py" daemon --agent_conf "$AGENT_CONF_DEST"
EOF
  chmod 0755 "$WRAPPER_BIN"
  ln -sf "$WRAPPER_BIN" /usr/local/bin/flexiwan-agent

  echo "[setup-flexiwan] Installing systemd unit"
  cat <<'EOF' >"$SYSTEMD_UNIT"
[Unit]
Description=flexiWAN Agent
After=network-online.target auditd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/flexiwan/bin/flexiwan-agent
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=/opt/flexiwan/src/flexiagent
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"

  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl --root=/ enable flexiwan-agent.service; then
      echo "[setup-flexiwan] WARNING: failed to enable service (systemd may be inactive during installation)" >&2
    fi
  fi
}

finalize_message() {
  cat <<'EOF'
[setup-flexiwan] Provisioning complete.
Next steps:
  - Reboot into the installed system.
  - Place your device token in /etc/flexiwan/agent/token.txt.
  - Run 'sudo systemctl start flexiwan-agent.service' on first boot if not started automatically.
EOF
}

install_packages
stage_repositories
setup_python_env
install_agent_assets
install_motd
copy_seed_assets

if [[ $RECONFIGURE -eq 1 ]]; then
  echo "[setup-flexiwan] Reconfiguration mode complete"
fi

finalize_message
