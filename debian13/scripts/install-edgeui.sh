#!/bin/bash
set -euo pipefail
root=${1:?target rootfs required}
source_ui=${2:?extracted official Edge UI directory required}
base=/usr/share/flexiwan/agent/edgeui
install -d "$root$base/backend" "$root$base/client"
install -m 0644 "$source_ui"/backend/*.py "$source_ui"/backend/*.conf "$root$base/backend/"
python3 "$(dirname "$0")/fix-edgeui-pyjwt.py" "$root$base/backend/access.py"
python3 "$(dirname "$0")/fix-edgeui-checker.py" "$root$base/backend/mediator.py"
python3 "$(dirname "$0")/fix-edgeui-interfaces.py" "$root$base/backend/mediator.py"
cp -r "$source_ui/backend/commands" "$root$base/backend/"
rsync -rt --exclude='*.pem' --exclude='*.jwt' "$source_ui/client/" "$root$base/client/"
chroot "$root" /opt/flexiwan/venv/bin/python -c 'import PAM, cherrypy, jwt, ruamel.yaml, psutil'
PYTHONPATH=/opt/flexiwan/src/flexiagent:/opt/flexiwan/src/flexiagent/tools/system_checker chroot "$root" /opt/flexiwan/venv/bin/python -c "import sys; sys.path.insert(0, '$base/backend'); import web_service"
install -m 0644 "$(dirname "$0")/../config/systemd/flexiwan-router-ui.service" "$root/etc/systemd/system/"
systemctl --root="$root" enable flexiwan-router-ui.service
