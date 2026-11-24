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
  --flexiwan-version 6.6.0 \
  --ubuntu-url https://releases.ubuntu.com/20.04.6/ubuntu-20.04.6-live-server-amd64.iso
```

Key options:

- `--flexiwan-version` — version string embedded in filenames and metadata (defaults to `6.6.0`).
- `--flexiagent-ref` — pinned git tag/ref for `flexiagent` (defaults to `v6.6.0`; also configurable via `FLEXIAGENT_REF`). Companion pins are `flexirouter` (`v21.01.03`), `flexiroutervpp` (`v26.02-rc0`), and `flexiroutersb` (`v21.01.02.09.13-rc0`); `flexiwancharts` remains unpinned (TBD) per `docs/baseline-6.5.x.md`.
- `--ubuntu-url` — alternate base Ubuntu live-server ISO.
- `--output` — custom output path (defaults to `dist/flexiEdge.focal.<version>.iso`).
- `--skip-cache` — avoid packaging local `.deb` files from `cache/packages/`.
- `--keep-workdir` — preserve `.work/staging/` for debugging and post-build manifest verification.

The build output (`.iso` + `.sha256`) is written to the `dist/` directory. Local clones of the flexiWAN repositories are automatically archived into the ISO (pinned repos — `flexiagent` at `FLEXIAGENT_REF`, `flexirouter` at `v21.01.03`, `flexiroutervpp` at `v26.02-rc0`, and `flexiroutersb` at `v21.01.02.09.13-rc0` — are archived via `git archive` without mutating the working tree; `flexiwancharts` remains unpinned/TBD) and recorded in `nocloud/repos/manifest.json`. The flexiManage baseline remains `6.5.1` while flexiEdge and `flexiagent` are `6.6.0`; compatibility must be validated by QEMU/E2E before release (see `docs/baseline-6.5.x.md`).

## Verifying build artifacts

The default build removes `.work/staging/` after creating the ISO. To verify a newly built ISO alongside its generated `manifest.json`, pass `--keep-workdir` to `scripts/build_iso.sh` and then run `scripts/verify-iso.sh`:

```bash
./scripts/build_iso.sh \
  --flexiwan-version 6.6.0 \
  --keep-workdir

./scripts/verify-iso.sh \
  --iso dist/flexiEdge.focal.6.6.0.iso \
  --manifest .work/staging/nocloud/repos/manifest.json
```

To run the verifier locally without building a full ISO (the same check CI executes), point it at the committed fixture in `tests/fixtures/`:

```bash
./scripts/verify-iso.sh \
  --iso tests/fixtures/flexiEdge.focal.6.6.0.iso \
  --manifest tests/fixtures/manifest.json
```

## Optional: Artifact Signing

ISO images can optionally be signed with a GPG detached signature (`.asc`) using an existing signing key on the release host. No private keys or passphrases are stored in this repository.

```bash
GPG_KEY_ID="<your-gpg-key-id>" ./scripts/sign-iso.sh dist/flexiEdge.focal.6.6.0.iso
```

This creates `dist/flexiEdge.focal.6.6.0.iso.asc`. Recipients can verify the signature with:

```bash
gpg --verify dist/flexiEdge.focal.6.6.0.iso.asc dist/flexiEdge.focal.6.6.0.iso
```

## Installing flexiEdge

1. Boot the target hardware/VM from the generated ISO.
2. Choose **Install flexiWAN router (UEFI)** from the boot menu (serial console option also available).
3. The unattended installer will:
   - Lay down Ubuntu Server with hostname `flexiedge` and admin user `flexiwan` (bootstrap password `flexiwan` is expired automatically via cloud-init `chpasswd.expire` and `chage -d 0`, forcing a password change on first login).
   - Install the base networking and build toolchain.
   - Execute `/cdrom/nocloud/setup-flexiwan.sh` to stage the flexiWAN services.
4. After reboot, log in (set a new strong password when prompted) and place your device token in `/etc/flexiwan/agent/token.txt`.
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
- `scripts/verify-iso.sh` — shell syntax, ISO checksum, and manifest verification.
- `scripts/sign-iso.sh` — optional GPG detached signing helper (`GPG_KEY_ID`).
- `scripts/bootstrap.sh` — dependency installer for the build host.
- `tests/fixtures/` — minimal ISO/SHA256/manifest fixtures used by CI.
- `docs/` — architecture, design notes, and 6.6.0 baseline pins.
- `cache/packages/` — optional offline `.deb` cache injected into the ISO.

## Next steps

- Populate `/etc/flexiwan/agent/token.txt` with a device token from flexiManage to complete registration.
- Extend `config/scripts/setup-flexiwan.sh` with hardware-specific drivers or monitoring agents as required.
- Consider integrating automated tests (e.g., Packer or QEMU CI) to boot the ISO and validate the provisioning flow end-to-end.
