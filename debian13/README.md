# flexiEdge Debian 13 (Trixie) Installation ISO Builder

Builds a self-installing, offline-capable **Debian 13 (Trixie)** UEFI installation ISO for **flexiWAN flexiEdge**, matching the official flexiWAN 6.5.1 installation experience:

- **UEFI Boot Menu** with VGA (`Install flexiWAN router (UEFI)`) and Serial (`Install flexiWAN router via serial port (UEFI)`, `115200n8`) modes
- **Interactive TUI Wizard** (`whiptail`): Welcome -> EULA -> Select target drive (always, including a single disk) -> Destroy warning -> Partition (**EFI + Main Root + Recovery**) -> Offline SquashFS deploy with a moving gauge -> Auto-reboot
- **Offline Recovery Partition**: Dedicated `FLEXI_RECOVERY` partition with GRUB recovery boot entry
- **Default Credentials**: `admin` / `flexiwan`

## Quick Start

### 1. Install host build & test dependencies (requires `sudo`)
```bash
sudo ./scripts/00-bootstrap-host.sh
```

### 2. Build the Debian 13 ISO
```bash
sudo ./scripts/build-all.sh --version 6.5.1
```
Output is written to `dist/flexiEdge.trixie.6.5.1.iso` and `dist/flexiEdge.trixie.6.5.1.iso.sha256`.

### 3. Test installation & boot in QEMU (UEFI + Serial)
```bash
./scripts/test-iso-qemu.sh dist/flexiEdge.trixie.6.5.1.iso
```

## Pipeline Stages
1. `scripts/01-fetch-components.sh` — Clones `Aikonlee/{flexiagent,flexiRouter,flexiRouterVPP,flexiRouterSB,flexiWANCharts}` and writes `manifest.json`.
2. `scripts/02-build-rootfs.sh` — Runs `debootstrap trixie`, installs kernel, networking stack, `flexiagent` (in `/opt/flexiwan/venv`), and packs `filesystem.squashfs`.
3. `scripts/03-build-installer-live.sh` — Builds the minimal Debian 13 Live installer environment with `flexiwan-installer.sh` auto-launched on `tty1` and `ttyS0`.
4. `scripts/04-build-iso.sh` — Generates the UEFI EFI boot image and packages the final Hybrid ISO with `xorriso`.
