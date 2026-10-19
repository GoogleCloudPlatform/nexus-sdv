# aaos/ — Nexus SDV for AAOS SDV vehicles

The vehicle-side software of Nexus SDV, the samples that use it, and the library for their
cloud counterparts.

## Overview

The Nexus-Bridge APEX connects an AAOS SDV vehicle to the Nexus cloud:

- **`aaos-nexus-sdv-tcu`** — shell for the Nexus-Bridge APEX.
- **`nexus-connectivity-agent`** — manages the vehicle's connectivity: its security and its
  NATS connection to the Nexus cloud.
- **`nexus-bridge`** — SDV service bundle that connects SDV services and their messages with
  the Nexus cloud.
- **`nexus-telemetry-client`** — sends the AAOS SDV telemetry reports to Nexus, as a standard
  client of the platform's Telemetry Service.

## Architecture

```
  Core (VM)                    Core3 / TCU (VM)                         Nexus cloud
┌──────────────┐            ┌──────────────────────────────┐
│ SDV service  │   dt       │ nexus-bridge                 │
│ bundle       │ ────────▶  │   service bundle             │
│              │ ◀────────  │   speaks no NATS, no network │
└──────────────┘            │        ▲  │                  │
                            │        │  ▼  unix socket     │
                            │ nexus-connectivity-agent     │        NATS
                            │   NATS leaf node             │ ─────────────▶ pubsub.<vin>.<topic>
                            │   credentials, provisioning  │ ◀─────────────
                            └──────────────────────────────┘
```

## Directories

### On the vehicle

The Nexus-Bridge APEX Nexus delivers, and its SELinux policy.

| Directory | Contents |
|---|---|
| [`aaos-nexus-sdv-tcu/`](aaos-nexus-sdv-tcu/README.md) | Shell for the Nexus-Bridge APEX, with its provisioning scripts and acceptance tests. |
| [`aaos-nexus-sdv-tcu-sepolicy/`](aaos-nexus-sdv-tcu-sepolicy/README.md) | SELinux policy for the Nexus-Bridge APEX. |
| [`nexus-bridge/`](nexus-bridge/README.md) | SDV service bundle that connects SDV services and their messages with the Nexus cloud. |
| [`nexus-connectivity-agent/`](nexus-connectivity-agent/README.md) | Manages the vehicle's connectivity: its security and its NATS connection to the Nexus cloud. |
| [`nexus-telemetry-client/`](nexus-telemetry-client/README.md) | Telemetry client in the Nexus-Bridge APEX: sends the AAOS SDV telemetry reports to Nexus, as a standard client of the platform's Telemetry Service. |

### Samples and cloud side

Samples that show the paths end to end, and the library their cloud counterparts are built
on.

| Directory | Contents |
|---|---|
| [`nexus-sdv-sample/`](nexus-sdv-sample/) | Sample AAOS SDV service bundles that interact with their cloud counterparts in Nexus SDV. |
| [`google-quickstart/`](google-quickstart/README.md) | Google's quickstart `Manager`, publishing the tyre pressure for the samples. |
| [`nexus-vhal-example/`](nexus-vhal-example/README.md) | AAOS IVI app that sends VHAL properties as telemetry to Nexus SDV. |
| [`nexus-aaos-sdk/`](nexus-aaos-sdk/README.md) | Rust library for cloud services that exchange messages with vehicles. |

### Shared sources and tools

| Directory | Contents |
|---|---|
| [`common/`](common/README.md) | Rust sources shared by the vehicle-side components. |
| [`vsidl-generate.sh`](vsidl-generate.sh) | Tool that wraps the AAOS SDV `vsidlc`. |
| [`test-environment/`](test-environment/README.md) | Tools for maintaining Cuttlefish hosts and instances. |

## Documentation

- [INSTALL.md](INSTALL.md) — building, installing, provisioning and testing.
- [NEXUS-AAOS-SDK.md](NEXUS-AAOS-SDK.md) — writing a service pair across vehicle and cloud.
