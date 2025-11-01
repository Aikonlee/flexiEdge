# flexiEdge ISO Builder

This project assembles a self-installing flexiWAN flexiEdge image that provisions the open-source SD-WAN stack during installation. It combines the upstream flexiWAN repositories with Ubuntu Server autoinstall to deliver a reproducible router appliance.

## Prerequisites

Run the bootstrap script once on the build host (Ubuntu/Debian recommended):

```bash
sudo ./scripts/bootstrap.sh
```

This installs ISO authoring tools (`xorriso`, `cloud-image-utils`, `squashfs-tools`, etc.) required by `scripts/build_iso.sh`.

## Building an ISO

```bash
./scripts/build_iso.sh \
  --flexiwan-version 6.4.32 \
  --ubuntu-url https://releases.ubuntu.com/20.04.6/ubuntu-20.04.6-live-server-amd64.iso
```

Key options:

- `--flexiwan-version` — version string embedded in filenames and metadata.
- `--ubuntu-url` — alternate base Ubuntu live-server ISO.
- `--output` — custom output path (defaults to `dist/flexiEdge.focal.<version>.iso`).
- `--skip-cache` — avoid packaging local `.deb` files from `cache/packages/`.
- `--keep-workdir` — preserve `.work/staging/` for debugging.

The build output (`.iso` + `.sha256`) is written to the `dist/` directory. Local clones of the flexiWAN repositories are automatically archived into the ISO and recorded in `nocloud/repos/manifest.json`.

## Installing flexiEdge

1. Boot the target hardware/VM from the generated ISO.
2. Choose **Install flexiWAN router (UEFI)** from the boot menu (serial console option also available).
3. The unattended installer will:
   - Lay down Ubuntu Server with hostname `flexiedge` and admin user `flexiwan` (`flexiwan` password — change on first login).
   - Install the base networking and build toolchain.
   - Execute `/cdrom/nocloud/setup-flexiwan.sh` to stage the flexiWAN services.
4. After reboot, log in and place your device token in `/etc/flexiwan/agent/token.txt`.
5. Start the agent if needed:

   ```bash
   sudo systemctl start flexiwan-agent.service
   ```

## Re-running provisioning

If the system needs to be reconfigured:

```bash
sudo /usr/local/sbin/flexiwan-setup --reconfigure
```

or run `config/scripts/recovery-reinstall.sh` from the ISO to locate the best available setup script automatically.

## Layout

- `config/autoinstall/` — Ubuntu autoinstall seed (user-data, meta-data).
- `config/scripts/` — provisioning, recovery helpers, and MOTD.
- `scripts/build_iso.sh` — ISO authoring workflow.
- `scripts/bootstrap.sh` — dependency installer for the build host.
- `docs/` — architecture and design notes.
- `cache/packages/` — optional offline `.deb` cache injected into the ISO.

## Next steps

- Populate `/etc/flexiwan/agent/token.txt` with a device token from flexiManage to complete registration.
- Extend `config/scripts/setup-flexiwan.sh` with hardware-specific drivers or monitoring agents as required.
- Consider integrating automated tests (e.g., Packer or QEMU CI) to boot the ISO and validate the provisioning flow end-to-end.
