# IoT Client Architecture

This document explains the architecture decisions and design rationale behind the ESP32 IoT client firmware.

## Overview

The IoT client runs on an ESP32 microcontroller with ~520KB of SRAM, no OS, and no heap management like a desktop system.
Every design decision is shaped by these constraints: fixed memory budgets, no dynamic linking, and a single-threaded cooperative execution model.

The firmware authenticates with a Keycloak identity provider using mTLS, then publishes protobuf-encoded telemetry to a NATS message broker.
The initial device registration (factory certificate to operational certificate exchange) must be done externaly; this firmware only handles the post-registration lifecycle.

```
+------------------+     +----------+     +------+
| ESP32            |     | Keycloak |     | NATS |
|                  |     |          |     |      |
| 1. Load op cert  |     |          |     |      |
|    + key from    |     |          |     |      |
|    LittleFS      |     |          |     |      |
|                  |     |          |     |      |
| 2. Get JWT ------+---->| Validate |     |      |
|    (mTLS:op cert)|     | cert     |     |      |
|    <-------------+-----| Return   |     |      |
|                  |     | JWT      |     |      |
|                  |     |          |     |      |
| 3. PUB telemetry-+-----+----------+---->| Auth |
|    (JWT token)   |     |          |     | Store|
+------------------+     +----------+     +------+
```

## State Machine

The firmware is driven by a state machine in the `loop()` function.
Each call to `loop()` executes one state transition, keeping the MCU responsive (no long blocking calls).

```
STATE_WIFI_CONNECT
        |
        v
  STATE_NTP_SYNC
        |
        v
  STATE_LOAD_CERTS
        |
        v
  STATE_AUTHENTICATE  <------+
        |                     |
        v                     |
  STATE_NATS_CONNECT          |  token expiring
        |                     |
        v                     |
  STATE_SEND_TELEMETRY  ------+
```

### Why a state machine?

Arduino's (we use the Arduino framework [via PlatformIO's `framework = arduino`] as our programming model) execution model calls `loop()` repeatedly. A blocking sequential flow (connect, then auth, then send) would work for a one-shot program, but can't handle:

- **Retry with backoff**: each state can independently retry on failure without restarting from scratch.
- **Token refresh**: the telemetry loop transitions back to `STATE_AUTHENTICATE` when the JWT is expiring, then returns to `STATE_NATS_CONNECT` without re-loading certificates.
- **NATS keepalive**: the `STATE_SEND_TELEMETRY` state calls `nats_process()` on every `loop()` iteration to respond to PING/PONG, even between telemetry sends.
- **Deep sleep readiness**: the state machine can be entered at any point after a wake-up. With JWT persistence (future work), a device waking from deep sleep can skip directly to `STATE_AUTHENTICATE` or `STATE_NATS_CONNECT`.

## Security Architecture

### Certificate Lifecycle

The Nexus SDV platform defines a 4-stage client lifecycle (see `base-services/registration/docs/registration.puml`):

1. **Factory provisioning** (external): Device receives a factory certificate at manufacturing time.
2. **Registration** (external): Device presents factory cert to the registration server, receives an operational certificate.
3. **Authentication** (this firmware): Device presents operational cert to Keycloak via mTLS, receives a JWT.
4. **Data transmission** (this firmware): Device connects to NATS with the JWT, publishes telemetry.

This firmware handles stages 3 and 4. The operational certificate and key are pre-provisioned to the ESP32's LittleFS filesystem via `make uploadfs`.

### JWT Token Validation

Rather than tracking token lifetime with a timer (`millis()`), the firmware decodes the JWT's `exp` claim and compares it against real time from NTP:

```c
bool token_valid_for(const char *jwt, int min_remaining_seconds);
```

This approach:

- **Survives reboots and deep sleep**: `millis()` resets on every power cycle; the JWT `exp` claim is an absolute Unix timestamp.
- **Is the source of truth**: the token itself declares when it expires, not a timer that may drift or overflow (`millis()` wraps after ~49 days).
- **Enables token persistence**: a JWT saved to flash before deep sleep can be validated on wake-up without contacting Keycloak.

The JWT payload is decoded using a lightweight inline base64url decoder (~20 lines of C) and parsed with ArduinoJson. No JWT library dependency is needed because we only read the `exp` claim -- we don't verify the signature (that's the NATS Auth Callout's responsibility).


## Protobuf with Nanopb

### Why Nanopb?

Nanopb is a C-only protobuf implementation (~3KB code) that uses static, fixed-size arrays instead of dynamic memory allocation.
On an ESP32 with limited SRAM and no OS heap management, every allocation must be deterministic.


### The `.options` File

The key to Nanopb's static allocation is the `.options` file (`proto/telemetry.options`):

```
telemetry.TelemetryMessage.message_id    max_size:40
telemetry.TelemetryMessage.device_id     max_size:32
telemetry.TelemetryMessage.sensor_data   max_count:8
telemetry.SensorReading.value            max_size:64
telemetry.SensorReading.sensor           max_size:32
```

In standard protobuf, `string` fields are dynamically sized and `repeated` fields are dynamically counted.
The `.options` file converts them to fixed-size C arrays:

- `string message_id` becomes `char message_id[40]`
- `repeated SensorReading sensor_data` becomes `telemetry_SensorReading sensor_data[8]` + `pb_size_t sensor_data_count`

This means the entire `TelemetryMessage` struct has a known size at compile time. No heap allocations occur during serialization.

Without the `.options` file, Nanopb falls back to **callback-based encoding** (`pb_callback_t`), which requires manual buffer management and is significantly harder to use.
The options file uses protobuf fully-qualified names (dot notation like `telemetry.TelemetryMessage.message_id`), not the generated C struct names (underscore notation).


## NATS Client

### Why a Custom Client?

The official [nats.c](https://github.com/nats-io/nats.c) library requires OpenSSL, pthreads, and libuv/libevent — none of which are available on the ESP32. Porting it would mean replacing its threading layer, TLS backend, and event loop, at which point you've written a custom client anyway. The NATS text protocol is simple enough (`PUB subject size\r\npayload\r\n`) that a ~200-line implementation covers all publish-only needs.

### Minimal Protocol Implementation

The NATS client (`nats_client.cpp`) implements only what's needed for telemetry publishing:

| Command       | Direction        | Purpose                                   |
| ------------- | ---------------- | ----------------------------------------- |
| `INFO`        | Server -> Client | Server capabilities (parsed but not used) |
| `CONNECT`     | Client -> Server | Authentication with optional JWT          |
| `PUB`         | Client -> Server | Publish telemetry to a subject            |
| `PING`/`PONG` | Bidirectional    | Keepalive                                 |
| `-ERR`        | Server -> Client | Error handling (triggers disconnect)      |

Not implemented: `SUB` (subscribe), `MSG` (receive), queue groups, TLS.
This is sufficient for a publish-only telemetry device.

### C++ Object Lifecycle

The `NatsClient` struct contains a `WiFiClient tcp` member, which is a C++ class.
The struct is allocated with `new` (not `calloc`) to ensure the `WiFiClient` constructor runs:

```c
NatsClient *nats_create() {
    return new NatsClient();
}

void nats_destroy(NatsClient *nc) {
    if (!nc) return;
    nats_disconnect(nc);
    delete nc;
}
```

Using `calloc` would zero-fill the memory without calling the constructor, leaving `WiFiClient`'s internal pointers as NULL.
Subsequent calls to `tcp.connect()` would dereference these NULL pointers, causing a `LoadProhibited` panic on the ESP32.
The matching `delete` (not `free`) ensures the destructor runs, properly closing the socket.


### Optional Authentication

The NATS `CONNECT` message conditionally includes the `auth_token` field:

```c
if (token && token[0] != '\0') {
    connect_msg += ",\"auth_token\":\"";
    connect_msg += token;
    connect_msg += "\"";
}
```

This allows the same client to work with both authenticated (JWT) and unauthenticated (local development) NATS servers.


## Deep Sleep Considerations

The current firmware runs continuously, but the architecture is designed for a future deep sleep mode where the ESP32 wakes periodically (e.g., every 10 minutes) to send telemetry.

**What survives deep sleep:**
- LittleFS (flash storage): certificates, potentially cached JWT
- RTC memory (~8KB): small state like wake counter

**What does not survive deep sleep:**
- All RAM (static variables, heap allocations)
- `millis()` counter (resets to 0)
- WiFi connection, TCP sockets, NATS connection

**Implications for the current design:**

| Concern          | Current approach                         | Deep sleep ready?                                    |
| ---------------- | ---------------------------------------- | ---------------------------------------------------- |
| Token validation | JWT `exp` claim vs `time()`              | Yes -- absolute timestamp, not relative timer        |
| Certificates     | Loaded from LittleFS each boot           | Yes -- LittleFS survives deep sleep                  |
| WiFi             | Reconnects on each state machine entry   | Yes -- would reconnect on wake                       |
| NATS             | Persistent TCP connection with keepalive | No -- connection is per-wake-cycle                   |
| JWT storage      | In-memory only                           | Needs work -- must persist to LittleFS or RTC memory |

The token validation via `exp` claim was specifically chosen over `millis()`-based tracking to enable this transition.
A deep sleep implementation would add JWT persistence to LittleFS and enter the state machine at `STATE_AUTHENTICATE` (checking the cached token first) rather than `STATE_WIFI_CONNECT`.
