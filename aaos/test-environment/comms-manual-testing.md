# Data Tunnel by hand

The on-image client `/system/bin/sdv_comms_client_rs` on a running mesh ([mesh.md](mesh.md)).

| | |
|---|---|
| adb | `/opt/cvd-host-sdv/bin/adb` |
| IVI | `0.0.0.0:6520` (instance1) |
| Core | `0.0.0.0:6521` (instance2) |
| Core3 | `0.0.0.0:6522` (instance3) |

## Authorization off, for the client only

The client is no registered service bundle; with `sdv.authz.enable=true` it aborts with `EX_SECURITY … passed_verification`. On userdebug builds:

```bash
adb -s 0.0.0.0:6521 shell setprop sdv.authz.enable false
adb -s 0.0.0.0:6522 shell setprop sdv.authz.enable false
```

Set it back to `true` afterwards. Other values: `disabled`, `permissions_only`, `acls_only`, `lenient`, `strict` ([enforcement](https://source.android.com/docs/automotive/sdv/workstreams/core/comms-authorization/enforcement)).

## Commands

```
sdv_comms_client_rs <discover|publish|subscribe|subscribe-mpub|get-last-message> …
```

Defaults: `--package-name google.sdv.comms`, `--bundle-name CommsClientApp`, `--service-unit-type CommsClientAppUnit`.

```bash
# all publications, all VMs (--vm-name for one)
adb -s 0.0.0.0:6522 shell /system/bin/sdv_comms_client_rs discover
# publish on Core: 200 messages, every 500 ms
adb -s 0.0.0.0:6521 shell /system/bin/sdv_comms_client_rs publish \
  --instance-name coreprobe --service-unit-name pressure --quantity 200 --interval-msec 500
# subscribe on Core3 by name only: the cross-VM test
adb -s 0.0.0.0:6522 shell /system/bin/sdv_comms_client_rs subscribe \
  --instance-name coreprobe --service-unit-name pressure --quantity 5
```

Result:

```json
{"Status":"Ok","Result":{"publisher_fqin":"instance2:google.sdv.comms.CommsClientApp/coreprobe",
  "messages_read":5,"messages_missed":0,"messages_corrupted":0,"messages_out_of_order":0}}
```

`instanceN` is the VM; healthy is `messages_read > 0` and all other counts `0`.

A publisher under an identity no installed bundle has stays invisible to other VMs; the default `google.sdv.comms.CommsClientApp` is visible.

## Cleanup

```bash
adb -s 0.0.0.0:6521 shell "pkill sdv_comms_clie; setprop sdv.authz.enable true"
adb -s 0.0.0.0:6522 shell "setprop sdv.authz.enable true"
```
