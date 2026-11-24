# flexiEdge ISO Build Design

## Overview

This repository assembles a fully automated flexiEdge installation ISO derived from the official flexiWAN open-source projects. The resulting image applies Ubuntu Server (20.04 LTS by default) and provisions the flexiWAN software stack — including `flexiagent`, `flexirouter`, `flexiroutervpp`, `flexiroutersb`, and `flexiwancharts` — during installation. The build system is designed for reproducibility, offline-friendly operation, and clear separation between the ISO authoring workflow and the post-install configuration that executes on the target appliance.

## High-level flow

1. **Author ISO** (`scripts/build_iso.sh`)
   - Downloads (or reuses) an Ubuntu live-server ISO.
   - Mounts the ISO into a staging directory via `xorriso`.
   - Injects flexiEdge autoinstall seed data (`config/autoinstall`) and provisioning scripts (`config/scripts`).
   - Bundles local git workspaces for the flexiWAN components into tarballs placed under `nocloud/repos` with an accompanying manifest (`manifest.json`).
   - Optionally copies locally cached Debian packages (`cache/packages/*.deb`).
   - Updates GRUB menus with dedicated flexiWAN installer entries (standard and serial console).
   - Rebuilds the ISO image, emits a SHA-256 checksum, and writes metadata into `dist/`.

2. **Install appliance**
   - During boot, Ubuntu autoinstall consumes `nocloud` data to perform unattended installation, create the `flexiwan` administrator account, install base OS packages, and register the late-stage provisioning hook.
   - In the `late-commands` phase, `/cdrom/nocloud/setup-flexiwan.sh` runs inside the target filesystem to install the flexiWAN stack.

3. **Post-install provisioning** (`config/scripts/setup-flexiwan.sh`)
   - Installs OS packages required by the agent, networking stack, and optional tooling.
   - Extracts bundled git repositories (or clones remote fallbacks) into `/opt/flexiwan/src`.
   - Creates a Python virtual environment in `/opt/flexiwan/venv` and installs `flexiagent` dependencies.
   - Installs agent configuration into `/etc/flexiwan/agent`, prepares an empty device token placeholder, and writes build metadata.
   - Deploys a reusable wrapper (`/opt/flexiwan/bin/flexiwan-agent`) and a `systemd` unit (`flexiwan-agent.service`).
   - Copies provisioning assets into `/var/lib/flexiwan/install-cache` and `/usr/local/sbin/flexiwan-setup` for future reconfiguration runs.
   - Optionally installs any bundled `.deb` packages and a custom login banner.

4. **Recovery & reprovisioning** (`config/scripts/recovery-reinstall.sh`)
   - Provides a simple helper that re-invokes the setup script from the ISO, cached copy, or `/usr/local/sbin/flexiwan-setup` in `--reconfigure` mode. This allows administrators to reinstall the software stack without rebuilding the entire system.

## Key directories and artefacts

| Path | Purpose |
|------|---------|
| `config/autoinstall/` | Cloud-init autoinstall seed (user-data, meta-data) that controls unattended OS installation. |
| `config/scripts/` | Provisioning (`setup-flexiwan.sh`), recovery helper, and MOTD assets copied into the ISO. |
| `cache/packages/` | Optional location for offline `.deb` packages; copied into the ISO when present. |
| `dist/` | Output ISO (`flexiEdge.focal.<version>.iso`) and checksum files. |
| `scripts/bootstrap.sh` | Installs host dependencies required for authoring an ISO (xorriso, squashfs-tools, etc.). |
| `scripts/build_iso.sh` | Main orchestrator for generating the ISO, bundling repositories, and producing metadata. |
| `nocloud/` *(inside ISO)* | Contains autoinstall data, provisioning scripts, repository tarballs, and cached packages consumed by the installer. |

## Autoinstall profile

The autoinstall profile provisions an Ubuntu Server instance with the following characteristics:

- Hostname: `flexiedge`
- Admin user: `flexiwan` (bootstrap password `flexiwan` is expired via cloud-init `chpasswd: { expire: true }` and `chage -d 0 flexiwan` so a password change is enforced on first login)
- Timezone: UTC, locale and keyboard set to US English.
- SSH server enabled by default.
- Package set includes Git, Python build tooling, StrongSwan, Open vSwitch, and utilities required by `flexiagent`.
- Late command triggers `/cdrom/nocloud/setup-flexiwan.sh` after the root filesystem is applied.

## Repository bundling manifest

`build_iso.sh` writes `nocloud/repos/manifest.json`, capturing metadata for each repository included with the ISO:

```json
{
  "generated_at": "2025-11-01T00:00:00Z",
  "flexiedge_version": "<requested version>",
  "flexiagent_ref": "v6.5.19",
  "ubuntu_base_url": "https://releases.ubuntu.com/20.04.6/...",
  "repositories": [
    {"name": "flexiagent", "ref": "v6.5.19", "commit": "<sha>", "archive": "flexiagent.tar.gz", "remote": "https://github.com/Aikonlee/flexiagent.git"}
  ]
}
```

When the installer runs without a bundled archive, `setup-flexiwan.sh` falls back to cloning the repository from its remote URL (checking out the pinned `ref` such as `FLEXIAGENT_REF=v6.5.19` when configured). The manifest is also copied into `/etc/flexiwan/build-info.json` on the installed system for audit purposes.

## Recovery workflow

- Bulk provisioning assets are cached to `/var/lib/flexiwan/install-cache` and `/usr/local/sbin/flexiwan-setup`.
- Administrators can re-run provisioning with `sudo /usr/local/sbin/flexiwan-setup --reconfigure`.
- `config/scripts/recovery-reinstall.sh` provides an on-ISO helper that locates the best available setup script and re-executes it.

## Validation & future work

- Run `scripts/verify-iso.sh --iso tests/fixtures/flexiEdge.focal.6.5.19.iso --manifest tests/fixtures/manifest.json` (which syntax-checks every shell script under `scripts/` and `config/scripts/` with `bash -n`) before committing changes.
- Optionally enable `shellcheck` for deeper linting.
- The current flow depends on the default Ubuntu 20.04 live-server ISO; update `--ubuntu-url` to switch bases (e.g., Ubuntu 22.04).
- Additional components such as VPP dataplane tuning, FRR templates, or hardware-specific drivers can be injected by placing assets under `config/scripts/` and extending `setup-flexiwan.sh`.
- To embed a complete offline package cache, populate `cache/packages/` with the required `.deb` files prior to building the ISO.
