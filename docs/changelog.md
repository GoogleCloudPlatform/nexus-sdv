# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Removed

## [1.2.0] - 2026-06-23

### Added
- **Telemetry Web Client**: Renders a fleet overview and per-device time-series view, with built-in support for GPS track maps. Pre-integrated with the new Trip Analyzer Sample Service.
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

[1.2.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/GoogleCloudPlatform/nexus-sdv/releases/tag/v1.0.0