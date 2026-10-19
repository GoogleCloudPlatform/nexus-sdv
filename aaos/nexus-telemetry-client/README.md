# nexus-telemetry-client

Sends the AAOS SDV telemetry reports to Nexus, as a standard client of the platform's Telemetry Service.
Part of the Nexus-Bridge APEX ([`aaos-nexus-sdv-tcu/`](../aaos-nexus-sdv-tcu/README.md)).

## What it does

- Activates its metrics configuration with the Telemetry Service on its VM.
- Publishes each `MetricsReport` unchanged on `telemetry-aaos-sdv.<VIN>`, through the leaf at `127.0.0.1:4222`.
- Asks the `nexus-connectivity-agent` for the VIN on `nexus.identity.vin`.
- Stays idle when `persist.nexus.telemetry_client.enabled` is `false`.

## Switching it off

At installation: `NEXUS_TELEMETRY_CLIENT=off ./provision-and-run.sh …`. Later:

```bash
adb shell setprop persist.nexus.telemetry_client.enabled false
adb shell 'stop nexus_telemetry_client; start nexus_telemetry_client'
```

## Files

| Path | Contents |
|---|---|
| `core/` | leaf address, switch and leaf session; `cargo test` on the host |
| `src/` | the binary with Google's telemetry SDK |
| `metrics/vehicle_telemetry_config_live.textproto` | the metrics configuration installed, report type `VehicleTelemetryData`, speed from `telemetry_sample_publisher` |
| `metrics/vehicle_telemetry_config_drive.textproto` | the same report with the speed from Google's driving simulation; not installed |
| `set-sdk-min-sdk-version.py` | sets `min_sdk_version: "35"` on Google's telemetry SDK modules; called by the APEX's staging script |
| `start-sample-publisher.sh` | starts Google's sample publisher, the source of the speed; needed after every boot |

## Seeing it work

```bash
adb logcat -d -s nexus-telemetry-client
# … connected to the leaf at 127.0.0.1:4222, publishing telemetry-aaos-sdv.<VIN>
```
