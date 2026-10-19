# SELinux policy for the Nexus-Bridge APEX

Product policy for the image; the programs it covers are in the Nexus-Bridge APEX.

| File | Contents |
|---|---|
| `nexus_connectivity_agent.te` | Domain `nexus_connectivity_agent` of the `nexus-connectivity-agent`. |
| `nexus_nats_server.te` | Domain `nexus_nats_server` of the `nats-server`. |
| `nexus_telemetry_client.te` | Domain `nexus_telemetry_client` of the `nexus-telemetry-client`. |
| `file.te`, `file_contexts` | Type `nexus_data_file` of `/data/misc/nexus`. |
| `property.te`, `property_contexts` | Property `persist.nexus.telemetry_client.enabled`. |

`aaos-nexus-sdv-tcu/stage-into-aosp.sh` adds this line to `device/google/sdv/sdv_core_cf/sdv_core_cf.mk`:

```
PRODUCT_PRIVATE_SEPOLICY_DIRS += vendor/nexus/aaos-nexus-sdv-tcu-sepolicy
```

The guests run SELinux permissive; enforcing is in progress, not tested.
