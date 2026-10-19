# aaos-nexus-sdv-tcu

Shell for the Nexus-Bridge APEX `com.android.nexus.aaos_nexus_sdv_tcu`, with its provisioning scripts and acceptance tests.

## Contents of the APEX

| Part | Source |
|---|---|
| `nexus-connectivity-agent` | [`../nexus-connectivity-agent/`](../nexus-connectivity-agent/README.md) |
| `nats-server` | upstream release, fetched by `fetch-nats-server.sh` in the hub's version |
| Nexus Bridge | [`../nexus-bridge/`](../nexus-bridge/README.md) |
| `nexus-telemetry-client` and its metrics configuration | [`../nexus-telemetry-client/`](../nexus-telemetry-client/README.md) |
| Init files of the two services | `init/` |

The SELinux policy is on the image: [`../aaos-nexus-sdv-tcu-sepolicy/`](../aaos-nexus-sdv-tcu-sepolicy/README.md).

## Files

| File | Contents |
|---|---|
| `Android.bp`, `apex_manifest.json`, `file_contexts`, `linker.config.json`, `sdv_service_bundles_manifest.textproto`, `orch/`, `init/` | the APEX |
| `com.android.sdv.samples.{avbpubkey,pem}` | Google's samples development key, pre-trusted on stock SDV images |
| `fetch-nats-server.sh` | fetches the `nats-server` in the hub's version |
| `stage-into-aosp.sh` | stages the APEX's sources and its policy into an AOSP tree |
| `check-nexus-cloud.sh` | checks the Nexus cloud from the host |
| `provision-and-run.sh` | provisions the vehicle and runs `check-leaf-connection.sh` |
| `check-leaf-connection.sh` | acceptance check of the link to the hub |
| `round-trip-test.sh`, `registry-test.sh` | end-to-end tests |
| `TESTING.md` | the acceptance tests |
| `tests/` | the scripts' tests, without a device |

## Building

```bash
./fetch-nats-server.sh nats.<base-domain>
./stage-into-aosp.sh <aosp-root>
cd <aosp-root> && source build/envsetup.sh && lunch sdv_core_cf-trunk_staging-userdebug
m com.android.nexus.aaos_nexus_sdv_tcu
```

A new version needs a higher `version` in `apex_manifest.json`. The whole path: [`../INSTALL.md`](../INSTALL.md).
