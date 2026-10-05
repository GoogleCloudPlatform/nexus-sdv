# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Removed

## [1.2.1] - 2026-10-02

### Added
- **Factory Helper Service**: Keycloak-protected endpoint issuing per-VIN factory identities through GCP Certificate Authority Service, so partners and test environments can onboard vehicles without a Google Cloud account of their own. They need the endpoint and an OIDC client secret, not project access. Bring-your-own-CSR or server-side generation; deploys into its own `factory` namespace (remote PKI only).
- **Vehicle Registry Service** (`base-services/vin-registry`): New base service recording every vehicle identity issued: VIN, issuing service, time and outcome. A successful issuance enrols the vehicle into the fleet, so it appears in FleetView without a hand-maintained list. Reporting is best effort: a certificate is never withheld because the registry is unavailable.
- **Platform Health Check**: Verifies APIs, infrastructure, certificate expiry, endpoints, the FleetView sign-in and the state of each base service, optionally pushing real telemetry through the platform and reading it back. Reports pass/warn/fail counts to a Cloud Monitoring dashboard and runs at the end of every bootstrap.
- **Deployment test automation**: `iac/operating/nexus-matrix.sh` builds and tears down four platforms in sequence (local and remote PKI, arm64 and amd64) to establish that a fresh environment still comes up in every supported shape. Each cycle is preceded by `nexus-preflight.sh`, which refuses a project that still holds an earlier environment, and a teardown now clears the secrets and identities that would otherwise be inherited by the next platform.
- **Platform Tools**: `keycloak-provision-client.sh` creates OIDC clients with realm roles idempotently, the mechanism that protects the Factory Helper; `nexus-cert-status.sh` shows and renews the platform's five TLS certificates; `run-vehicle-client-factory.sh` and `run-python-client-factory.sh` walk the whole onboarding path (factory identity, registration, token, telemetry) with the operator secret supplied in the environment. A fresh platform provisions its own Keycloak objects: the `factory-operator` client, the `nexus-fleet` group and user, the `nexus-admin` role.
- **Agent skills (experimental)**: `nexus-install` and `nexus-operate` describe installing and operating a platform for an agent framework, together with `nexus-preflight.sh`, a read-only check of whether a Google Cloud project can take a platform at all. Published to be used and criticised; expect them to change.
- **Public PKI Trust Bucket**: TLS trust anchors published to a public, read-only GCS bucket; clients fetch them over HTTPS instead of needing Secret Manager access.

### Changed
- **Keycloak is reachable under two names** (remote PKI): `keycloak-ui.<domain>` serves browsers on 443 with a publicly trusted certificate, while `keycloak.<domain>:8443` keeps serving vehicles, whose client certificates a terminating load balancer cannot forward. Both paths issue one identical issuer. **Existing remote-PKI installations gain a `keycloak-ui` DNS record and a managed certificate.**
- **Telemetry Web Client (FleetView)**: The fleet overview is now called *Telemetry* and sits beside a new *Vehicle Registry* view listing the platform's vehicle identities. Opening one shows that vehicle's complete issuance history: every recorded event, newest first, with what was issued, by which service, and whether it succeeded. Access follows Keycloak group membership. A vehicle outside the viewer's fleets is neither shown nor disclosed, while the `nexus-admin` realm role sees every identity, including ones belonging to no fleet. Signs in with next-auth 4.24.15.
- **Credential lifetimes are configurable and layered**: factory certificates 730 days, operational certificates 90, both set in `.bootstrap_env` (`FACTORY_HELPER_CERT_VALIDITY_DAYS`, `OPERATIONAL_CERT_VALIDITY`). A factory identity is a vehicle's way back to a defined state, so it outlives every operational certificate derived from it.
- **Pinned external versions**: The NATS Helm chart is pinned to 2.14.6 and the BigTable connector image to wombat 1.0.7; both followed `latest` before, so platforms bootstrapped on different days could run different components.

## [1.2.0] - 2026-06-23

### Added
- **Telemetry Web Client (FleetView)**: Renders a fleet overview and per-device time-series view, with built-in support for GPS track maps. Pre-integrated with the new Trip Analyzer Sample Service.
- **Platform Deployment Test Automation**: Enables full GCP-based Nexus SDV platform deployment leveraging Cloud Build Triggers and Repositories, eliminating the requirement for local workstation execution.
- **Trip Analyzer Sample Service**: Reference business service built on top of Nexus SDV Core. Calculates driving scores based on live telemetry data received from the vehicle platform and publishes results to the Telemetry Web Client.
- **ESP32 IoT-Client**: Fully functional reference hardware implementation covering the complete edge-to-cloud data path, including deep-sleep power management and native GPS integration.
- **MQTT-NATS Data Converter**: Service that converts inbound edge telemetry from MQTT into the native Nexus Protobuf format (`TelemetryMessage`) and publishes it directly to NATS.

### Changed
- **`bootstrap-platform.sh`**: Extended to support Cloud Build test automation pipelines and updated the interactive routine to include configuration prompts for the Telemetry Web Client.
- **`teardown-platform.sh`**: Updated resource cleanup logic to cover components and artifacts provisioned by the new Cloud Build automation layer.

## [1.1.0] - 2026-03-31

### Added
- **GCP Cloud Build Support**: Introduced as a native alternative to GitHub Actions for platform bootstrapping, with the local cloned repo as the only dependency outside GCP.
- **ARM64 Architecture Support**: Full support for ARM-based Kubernetes nodes (e.g., Tau T2A), enabling potential infrastructure cost reduction.
- **Python In-Vehicle Client SDK**: Launch of the lightweight Python SDK, designed to accelerate custom telemetry service implementations.

### Changed
- **`bootstrap-platform.sh`**: Updated the interactive deployment script to include selection prompts for CI/CD providers (Cloud Build vs. GitHub) and CPU architectures (ARM vs. AMD64).
- **`teardown-platform.sh`**: Enhanced the decommissioning logic to ensure clean removal of GCP Cloud Build artifacts and architecture-specific GKE node pools.
- **Python Client**: Refactored existing client components to leverage the new unified In-Vehicle SDK for improved performance and modularity.

## [1.0.0] - 2026-01-15

### Added
- **Initial Release**: Complete reference implementation of the Nexus SDV connected vehicle platform.
- **Core Infrastructure and Compute Workloads**: Terraform-based and GitHub-action-based provisioning for GKE, BigTable, and NATS.
- **Identity & Access**: Integrated Vehicle Registration and Keycloak for mTLS-backed and OpenID authentication and authorization.
- **Sample Clients and Services**: Initial Go and JavaScript clients for telemetry and service interaction. Simple service reading data from BigTable.

---

[1.2.1]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/releases/tag/v1.0.0