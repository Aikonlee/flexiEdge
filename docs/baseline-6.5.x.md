# flexiEdge 6.6.0 Baseline & Component Pins

This document records the target **flexiEdge 6.6.0** baseline for the flexiEdge ISO builder, component pin status, open decisions, and compatibility with the **flexiManage 6.5.1** baseline.

> **Upstream docs note:** The official online flexiWAN documentation index still shows `6.4.1` / flexiManage `6.4.30` / flexiEdge `6.4.32`. We maintain this 6.6.0 baseline document (retained at `docs/baseline-6.5.x.md`) and compatibility table as our source of truth.

## Component Pins

Upstream flexiWAN repositories are hosted on GitLab; our maintained fallback mirrors are hosted on GitHub under `https://github.com/Aikonlee/<repo>.git`.

> **Pin verification note:** The four pinned tags below (`flexiagent`, `flexiRouterVPP`, `flexiRouterSB`, and `flexiRouter`) are **user-confirmed and verified to exist on GitHub**. `flexiWANCharts` has no confirmed pin yet and remains unpinned (TBD).

| Component | Repo Directory | Mirror Remote | Target Pin / Branch | Status |
| --- | --- | --- | --- | --- |
| `flexiagent` | `flexiagent` | `https://github.com/Aikonlee/flexiagent.git` | **`v6.6.0`** | **User-confirmed & tag-verified; pinned & enforced** (`FLEXIAGENT_REF="v6.6.0"` in `scripts/build_iso.sh` via `git archive` and in `config/scripts/setup-flexiwan.sh` via `git clone --branch`; ISO track label `FLEXIEDGE_VERSION_DEFAULT="6.6.0"`) |
| `flexiRouterVPP` | `flexiroutervpp` | `https://github.com/Aikonlee/flexiroutervpp.git` | **`v26.02-rc0`** | **User-confirmed & tag-verified; pinned & enforced** in `scripts/build_iso.sh` (`REPO_SOURCES`) and `config/scripts/setup-flexiwan.sh` |
| `flexiRouterSB` | `flexiroutersb` | `https://github.com/Aikonlee/flexiroutersb.git` | **`v21.01.02.09.13-rc0`** | **User-confirmed & tag-verified; pinned & enforced** in `scripts/build_iso.sh` (`REPO_SOURCES`) and `config/scripts/setup-flexiwan.sh` |
| `flexiRouter` | `flexirouter` | `https://github.com/Aikonlee/flexirouter.git` | **`v21.01.03`** | **User-confirmed & tag-verified; pinned & enforced** in `scripts/build_iso.sh` (`REPO_SOURCES`) and `config/scripts/setup-flexiwan.sh` |
| `flexiWANCharts` | `flexiwancharts` | `https://github.com/Aikonlee/flexiwancharts.git` | **TBD (unpinned)** | No pin provided yet; left unpinned (`ref: ""`) until confirmed |

### Open Decisions

1. **`flexiWANCharts` pin**: Confirm the exact tag/branch or commit SHA for `flexiWANCharts` to record in `scripts/build_iso.sh`, `config/scripts/setup-flexiwan.sh`, and `manifest.json` during release builds.

## Compatibility Matrix (flexiEdge ↔ flexiManage)

> **Compatibility note:** The flexiManage baseline remains `6.5.1`, while both the flexiEdge ISO track label and `flexiagent` are `6.6.0` (`v6.6.0`, with `flexiRouterVPP` / `flexiRouterSB` pinned to `-rc0` pre-release tags). Compatibility between flexiManage `6.5.1` and flexiEdge/agent `6.6.0` is **not yet proven** and **must be validated in QEMU/E2E before release**.

| Track | flexiManage Baseline | flexiEdge ISO / Agent Version | Companion Components (`VPP` / `SB` / `Router` / `Charts`) | Validation State |
| --- | --- | --- | --- | --- |
| **6.6.0 (Target)** | flexiManage **6.5.1** (production baseline `9a1125a`, `backend/package.json` `6.5.1`) | ISO **`6.6.0`** / `flexiagent` **`v6.6.0`** | `flexiRouterVPP` `v26.02-rc0` / `flexiRouterSB` `v21.01.02.09.13-rc0` / `flexiRouter` `v21.01.03` / `flexiWANCharts` TBD (unpinned) | 4 of 5 component pins user-confirmed & tag-verified (Charts TBD); flexiManage (`6.5.1`) ↔ flexiEdge/agent (`6.6.0`) protocol & tunnel compatibility **unproven — must be validated in QEMU/E2E before release** |
| **6.4.x (Legacy / Upstream Docs Index)** | flexiManage `6.4.30` (docs index `6.4.1`) | `6.4.32` (previous builder default) | Legacy 6.4.x | Superseded by 6.6.0 baseline |

## Security & Artifact Notes

- Default account `flexiwan` retains the bootstrap password hash in `config/autoinstall/user-data`, with password expiry enforced on first login (`chpasswd.expire: true` + `chage -d 0 flexiwan`).
- Build verification is automated in CI via `scripts/verify-iso.sh` against committed fixtures in `tests/fixtures/`.
- Optional detached GPG signing is provided by `scripts/sign-iso.sh` using `GPG_KEY_ID` from the release environment.
