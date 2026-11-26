# ADR-0001: Establish Repository Governance, Language Policy, and Graduation Model

| Field | Value |
| :--- | :--- |
| **Status** | Proposed |
| **Date** | 2026-11-16 |
| **Deciders** | @timkl7, @fhaubner, @danielelhsvaltech |
| **Related** | PR #84 |

## Context and Problem Statement

Nexus SDV splits development across `main`, parity-synced external mirrors, and an experimental `event-horizon-experience` branch holding Android Automotive OS (AAOS) Software-Defined Vehicle (SDV) prototypes. 
On `main`, code spans six languages (Rust, Go, Python, Java, C++/ESP32, TypeScript), duplicates `.proto` files, diverges from `docs.nexus-sdv.io`, and commits vendor-specific AI configs (`CLAUDE.md`).

Before restructuring `main` or graduating onboard code, how should the project organize repository domains, govern graduation onto `main`, bound in-repo languages, and maintain documentation and agent instructions?

- **In Scope:** Public-first workflow and donor-branch graduation, Phase 1 top-level layout, in-repository language policy, `docs/`-to-`docs.nexus-sdv.io` publishing, and vendor-neutral agent conventions (`AGENTS.md`, `.agents/plugins/`).
- **Out of Scope / Non-Goals:** Wire contracts, NATS subject taxonomy, and service discovery scope; AAOS SDV vs. standalone AAOS IVI; `cloud/` boundaries, `data-api`/`fleet-ui` retention, and network ingress; Nexus Bridge internals.

## Decision Drivers

- **Continuous `main` readiness:** Keep `main` deployable, security-reviewed, and passing lint, test, and Apache-2.0 license checks.
- **Unified vehicle-to-cloud developer model:** Use shared abstractions across onboard AAOS SDV services, SDKs, and cloud workloads.
- **Bounded CI and supply-chain surface:** Limit maintained toolchains and scanners without rewriting working Go cloud control-plane services.
- **Zero schema and doc drift:** Keep a single Git source of truth for `.proto` schemas, as-built docs, and `docs.nexus-sdv.io`.
- **Vendor-neutral contributor and agent workflows:** Support human contributors and AI agents without tool-specific config files.
- **Open-source governance:** Enforce Apache-2.0 licensing, CLA checks, and `CODEOWNERS` review on every change.

## Decision Outcome

Chosen option: **Domain-Partitioned Monorepo with Phase-Gated Graduation and Rust + Go Policy**, because top-level C4 Level 2 directories in one public repository remove schema and parity-sync drift, 
freezing `event-horizon-experience` protects `main` via small ADR-gated PRs, and limiting runtimes to Rust and Go (plus TypeScript for the UI) aligns vehicle and cloud development while keeping CI and security maintenance small.

## Considered Options

### 1. Domain-Partitioned Monorepo with Phase-Gated Graduation and Rust + Go Policy (Chosen)

Consolidate active development, PR review, quality gates, and as-built docs onto `main` in `GoogleCloudPlatform/nexus-sdv` under top-level C4 Level 2 directories:

- `proto/`: shared Protobuf/VSIDL schemas across vehicle and cloud (zero duplicate `.proto` copies).
- `cloud/`: GCP control- and data-plane services (consolidating `base-services/` and, pending ADR-0004, `fleet-ui/`).
- `sdv/` or `aaos/`: preliminary onboard Cargo/Soong workspace decided in ADR-0003 before Phase 2 (`sdv/` if standalone AAOS IVI is excluded, or `aaos/{core,sdv,ivi}` if included alongside AAOS SDV).
- `sdk/`: shared service SDK (`sdk/rust/`) with common vehicle and cloud communication traits.
- `samples/`: reference workloads and host simulators (`trip-analyzer/`, `simulators/`, `rust-client-server/`), retiring `iot-client/`, `data-converter/`, `devices/`, and `data-api-sampler/`.
- `iac/`: Terraform, Helm/`helmfile.d`, Cloud Build pipelines, and scripts (`bootstrapping/`, `operating/`).
- `docs/`: as-built `ARCHITECTURE.md`, `OPERATIONS.md`, contributor/security policies, and `docs/adr/`.
- `.agents/plugins/` and `.github/`: portable agent skills, `CODEOWNERS`, PR templates, and CI checks.

Governance rules:

1. **Phase-gated donor graduation:** Freeze `event-horizon-experience` read-only (never bulk-merged) and retire parity-sync scripts. Capabilities graduate onto protected `main` via single-purpose PRs (~300-500 LOC) linked to a feature, fix, or refactor using Squash & Merge and Conventional Commits (`release-please` SemVer). Embargoed work stages in an isolated private mirror or Copybara export and lands on `main` through the same PR checks once cleared.
2. **Rust + Go language policy:** Use **Rust** for onboard crates (`sdv/` or `aaos/`), `sdk/rust/`, and `samples/` (keeping existing Rust `cloud/` services `registration` and `factory-helper`). Allow **Go** only for cloud services in `cloud/` (`auth-callout`, `vin-registry`, `data-api`) tied to NATS hooks and GCP Go SDKs. Limit **TypeScript** to `cloud/fleet-ui/` and `iac/` to HCL, YAML, and Bash. Keep Python simulators/services only as temporary smoke tests until ported to Rust. External systems integrating over `proto/` wire contracts remain language-agnostic.
3. **Documentation and vendor-neutral agent support:** Update `docs/` in the same PR as code changes and publish `docs.nexus-sdv.io` via CI following C4 architecture guidelines. Remove `CLAUDE.md` and scratch plans; replace root `AGENTS.md` with a ~30-line, vendor-neutral file listing build/test/lint commands and linking to `docs/` and `.agents/plugins/nexus-sdv/skills/`.

**Pros**

- Keeps `main` deployable while setting Phase 1 directory boundaries once and deferring only the onboard root (`sdv/` vs. `aaos/{core,sdv,ivi}`) to ADR-0003.
- Removes duplicate `.proto` files, parity-sync overwrites, and portal drift through single-repo PRs.
- Uses one language (Rust) and one SDK model for vehicle and cloud feature code without rewriting working Go services.
- Works across coding agents via `docs/`, a short `AGENTS.md`, and `.agents/plugins/`.

**Cons**

- Splitting `event-horizon-experience` into ~300-500 LOC ADR-gated PRs takes more upfront planning than a single merge.
- Porting temporary Python samples and services to Rust adds migration work once `sdk/rust/` lands.

### 2. Same Monorepo and Graduation Model with Rust Onboard and Polyglot Cloud / Samples

Adopt the same domain-partitioned monorepo layout, donor-branch graduation rules, and documentation workflow as Option 1, but restrict the Rust requirement to onboard vehicle crates (`sdv/` or `aaos/`). Keep polyglot runtimes across `cloud/`, `sdk/`, and `samples/`, retaining Python (`trip-analyzer`, Python SDK/simulators) and Java (`data-api-sampler`) alongside Go and Rust while still retiring microcontroller `iot-client/`.

**Pros**

- Avoids porting existing Python and Java sample services and simulators to Rust.
- Lets cloud and data contributors build in-repo services in Python or Java without using Rust.

**Cons**

- Python and Java cloud services cannot share the Rust SDK communication traits used onboard, either splitting the vehicle and cloud programming model or requiring parallel SDKs per language.
- Keeps Dependabot, CVE patching, Trivy license scans, protobuf codegen, and CI running across four+ backend languages instead of two.

## Consequences

- **Positive:**
  - Wire contracts (`proto/`), onboard crates (`sdv/` or `aaos/`), cloud services (`cloud/`), IaC (`iac/`), and `docs/` change and test together in one PR.
  - Maintainer review, CVE patching, and CI drop to Rust and Go plus TypeScript for `cloud/fleet-ui/`.
  - Contributors and AI agents read the same documentation in `docs/`.
- **Negative / Trade-offs:**
  - Donor-branch features remain off `main` until ADR-0002..0006 and ~300-500 LOC PR slices merge.
- **Risks and Mitigations:**
  - **Risk:** Divergence between frozen `event-horizon-experience` and restructured `main` adds friction during Phase 2-3 graduation.
    **Mitigation:** Lock Phase 1 directories now, decide `sdv/` vs. `aaos/{core,sdv,ivi}` in ADR-0003 before Phase 2, and treat `event-horizon-experience` as a read-only reference rather than rebasing it.
  - **Risk:** Co-locating Android Soong (`sdv/` or `aaos/`) and GKE (`cloud/`, `iac/`) code slows PR checks if all jobs run on every change.
    **Mitigation:** Filter lint, test, and build jobs by top-level path, running full cross-domain checks when `proto/` changes.

## References

- [ADR Authoring Template](template.md)
- [Nexus SDV Documentation Portal](https://docs.nexus-sdv.io)
- [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
- [The C4 Model for Visualising Software Architecture](https://c4model.com/)
