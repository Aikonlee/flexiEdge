# flexiEdge 6.5.x Baseline & Component Pins

This document records the target **flexiWAN 6.5.x** baseline for the flexiEdge ISO builder, component pin status, open decisions, and compatibility with flexiManage 6.5.x.

> **Upstream docs note:** The official online flexiWAN documentation index still shows `6.4.1` / flexiManage `6.4.30` / flexiEdge `6.4.32`. We maintain this 6.5.x baseline document and compatibility table as our source of truth.

## Component Pins

Upstream flexiWAN repositories are hosted on GitLab; our maintained fallback mirrors are hosted on GitHub under `https://github.com/Aikonlee/<repo>.git`.

| Component | Repo Directory | Mirror Remote | Target Pin / Branch | Status |
| --- | --- | --- | --- | --- |
| `flexiagent` | `flexiagent` | `https://github.com/Aikonlee/flexiagent.git` | **`v6.5.19`** | **Pinned & enforced** (`FLEXIAGENT_REF="v6.5.19"` in `scripts/build_iso.sh` via `git archive` and in `config/scripts/setup-flexiwan.sh` via `git clone --branch`; default `FLEXIEDGE_VERSION_DEFAULT="6.5.19"`) |
| `flexiRouterVPP` | `flexiroutervpp` | `https://github.com/Aikonlee/flexiroutervpp.git` | **TBD (open decision)** | Stable 6.5.x-compatible tag still to be confirmed; do not guess |
| `flexiRouterSB` | `flexiroutersb` | `https://github.com/Aikonlee/flexiroutersb.git` | **6.5.x-compatible branch (TBD)** | Branch/commit to be confirmed during integration |
| `flexiRouter` | `flexirouter` | `https://github.com/Aikonlee/flexirouter.git` | **6.5.x-compatible branch (TBD)** | Branch/commit to be confirmed during integration |
| `flexiWANCharts` | `flexiwancharts` | `https://github.com/Aikonlee/flexiwancharts.git` | **6.5.x-compatible branch (TBD)** | Branch/commit to be confirmed during integration |

### Open Decisions

1. **`flexiRouterVPP` stable tag**: Confirm the exact VPP/router stable tag compatible with `flexiagent v6.5.19` and Ubuntu 20.04/22.04 target kernels before cutting a release ISO.
2. **`flexiRouterSB` / `flexiRouter` / `flexiWANCharts` branch pins**: Confirm the exact 6.5.x-compatible branch names and commit SHAs to record in `manifest.json` during release builds.

## Compatibility Matrix (flexiEdge ↔ flexiManage)

| Track | flexiManage Baseline | flexiEdge ISO / Agent Version | Companion Components (`VPP` / `SB` / `Router` / `Charts`) | Validation State |
| --- | --- | --- | --- | --- |
| **6.5.x (Target)** | flexiManage **6.5.x** (production baseline `9a1125a`, `backend/package.json` `6.5.1`) | **`6.5.19`** (`flexiagent v6.5.19`) | `flexiRouterVPP` tag TBD; `flexiRouterSB` / `flexiRouter` / `flexiWANCharts` 6.5.x branch TBD | P0 baseline & CI artifact verification in place; hardware/end-to-end tunnel validation pending component pin confirmation |
| **6.4.x (Legacy / Upstream Docs Index)** | flexiManage `6.4.30` (docs index `6.4.1`) | `6.4.32` (previous builder default) | Legacy 6.4.x | Superseded by 6.5.x baseline |

## Security & Artifact Notes

- Default account `flexiwan` retains the bootstrap password hash in `config/autoinstall/user-data`, with password expiry enforced on first login (`chpasswd.expire: true` + `chage -d 0 flexiwan`).
- Build verification is automated in CI via `scripts/verify-iso.sh` against committed fixtures in `tests/fixtures/`.
- Optional detached GPG signing is provided by `scripts/sign-iso.sh` using `GPG_KEY_ID` from the release environment.
