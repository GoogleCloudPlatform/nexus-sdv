# nexus-vhal-example

AAOS IVI app that sends VHAL properties as telemetry to Nexus SDV.

## What it does

- Lists the vehicle's VHAL properties with their current values, refreshed every 2 seconds.
- Sends the ticked properties every 2 seconds as a `TelemetryMessage` ([`proto/telemetry.proto`](../../proto/telemetry.proto)) on `telemetry.<VIN>`.
- Finds the leaf from the boot configuration line `androidboot.nexus.leaf=<address>:<port>`.
- Asks the `nexus-connectivity-agent` for the VIN on `nexus.identity.vin`.
- Holds no credential and asks only for permissions that read properties.

At the first start speed, gear and fuel level are ticked; the selection is kept.

## Build

JDK 21 or newer, Android SDK with API 37 (`sdk.dir` in `local.properties` or `ANDROID_HOME`).

```bash
make test      # unit tests
make build     # app/build/outputs/apk/debug/app-debug.apk
make install   # adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Check that it works

1. The status line reads `Leaf: reachable · VIN: <VIN>` and `Sent` counts up after *Start sending*.
2. A value set in the VHAL appears on the screen and in the cloud:

   ```bash
   adb root
   adb shell dumpsys android.hardware.automotive.vehicle.IVehicle/default --set 0x11600207 -f 15
   ```

3. In BigTable the readings are rows of the table `telemetry`, key starting with the VIN, column `dynamic:<property name>`.

The first permission question reads "access this device's location"; it is the permission for the vehicle's speed.

## If something is missing

| The screen shows | Meaning |
|---|---|
| `Leaf: not reachable (no leaf configured for this VM …)` | the boot configuration lacks `androidboot.nexus.leaf` |
| `Leaf: not reachable (…)` | the leaf does not answer; the app retries every 3 seconds |
| `VIN: not known` | the `nexus-connectivity-agent` has not answered yet |
| a row "not readable" | the app may not read that property |
