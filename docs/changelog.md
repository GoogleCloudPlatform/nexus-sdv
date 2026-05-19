# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Removed

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

[1.1.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/releases/tag/v1.0.0