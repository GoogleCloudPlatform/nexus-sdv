# AAOS SDV foundations of the Nexus Bridge

This document gives more information for [ADR-0005](../0005-nexus-bridge-v1.md). It gives the
facts about AAOS 17 with SDV that the options of the ADR use. Each term is a concept of AAOS SDV or
of the Android core platform.

## Terms

| Term | Concept of | Meaning | Reference |
|---|---|---|---|
| Service bundle | AAOS SDV | A module of related business logic. It operates as one Linux process in an SDV VM. Permissions apply to the full service bundle. | [Logical architecture](https://source.android.com/docs/automotive/sdv/core-areas/what-service) |
| SDV package | AAOS SDV | The package of one or more service bundles. Its manifest contains the authorization policies. An SDV package is an APEX. | [Logical architecture](https://source.android.com/docs/automotive/sdv/core-areas/what-service#sdv-package) |
| VSIDL | AAOS SDV | A language on top of protocol buffers. It defines the interfaces between service bundles with two kinds of type. A **message type** is the data on a topic, for example `TirePressure`. A **service type** is the RPC interface on a channel, for example `DoorControl`. | [VSIDL](https://source.android.com/docs/automotive/sdv/core-areas/vsidl), [Logical architecture](https://source.android.com/docs/automotive/sdv/core-areas/what-service) |
| Topic | AAOS SDV | A named path for publish/subscribe messages. | [Terminology](https://source.android.com/docs/automotive/sdv/overview/terminology) |
| Channel | AAOS SDV | A named path for RPC services. | [Terminology](https://source.android.com/docs/automotive/sdv/overview/terminology) |
| Data Tunnel | AAOS SDV | The publish/subscribe transport of the SDV middleware. | [VSIDL](https://source.android.com/docs/automotive/sdv/core-areas/vsidl), `sdv_comms/sdk/rs/dt/` |
| SDV Orchestrator, SDV Lifecycle Manager | AAOS SDV | The SDV Orchestrator starts a service bundle instance. The SDV Lifecycle Manager starts and monitors it. | [Logical architecture](https://source.android.com/docs/automotive/sdv/core-areas/what-service) |
| Telemetry Service | AAOS SDV | The service of AAOS SDV for data collection, edge processing and metrics reporting. | [AAOS SDV system architecture](https://source.android.com/docs/automotive/sdv/sdv-system-architecture), [Telemetry SDK](https://source.android.com/docs/automotive/sdv/workstreams/telemetry/sdk) |
| `AuthzPolicy` | AAOS SDV | The permissions of a service bundle. | `service_authz/proto/sdv/authz/policy/authz_policy.proto` |
| APEX | Android core platform | A signed container format for system components. An APEX updates independently of the system image. | [APEX](https://source.android.com/docs/core/ota/apex) |
| SELinux domain | Android core platform | A label for a process. The SELinux policy gives the permissions of each domain. | [SELinux](https://source.android.com/docs/security/features/selinux) |
| `init` | Android core platform | The process that starts native programs from `.rc` service definitions. | [init](https://android.googlesource.com/platform/system/core/+/main/init/README.md) |

A path in this document without a repository prefix is a file in the AOSP source tree, release
android-17.0.0_r1, in the directory `system/software_defined_vehicle/`. A path that starts with
`/` is a path on the device.

## 1. Integration into the SDV communication

### How the Nexus Bridge uses the Data Tunnel

The Data Tunnel is the publish/subscribe transport of the SDV middleware. It gives the payload
as bytes and does not decode it (`sdv_comms/sdk/rs/dt/subscriber.rs:138-160`).

A typical service bundle uses the code that `vsidlc` makes from its VSIDL files. This code decodes
the protobuf messages. The Nexus Bridge uses the Data Tunnel directly, one layer below this code,
and forwards the bytes. Thus, the code of the Nexus Bridge does not change for a new message type.

### Network access

A service bundle operates in the SELinux domain `untrusted_service_bundle`. This domain has no
`tcp_socket` permissions. It permits a Unix socket in the data directory of the bundle (audit log
of the device).

## 2. Permissions of a service bundle

The SDV package contains the signed `AuthzPolicy` of each service bundle. Each entry gives a
message type or a service type, and a topic or a channel. The platform has one check for each
entry:

| Entry | Check | Question |
|---|---|---|
| `Publisher` | `can_publish` | Can the bundle publish this message type on this topic? |
| `Subscriber` | `can_subscribe` | Can the bundle subscribe to this message type on this topic? |
| `Server` | `can_serve` | Can the bundle supply this service type on this channel? |
| `Client` | `can_call` | Can the bundle call this service type on this channel? |

Three fields make an entry or a policy wider:

| Field | Scope | Effect |
|---|---|---|
| `allow_all_topics` | one `Publisher` or `Subscriber` entry | all topics of that one message type |
| `allow_all_channels` | one `Server` or `Client` entry | all channels of that one service type |
| `allow_read_all` | the full policy | `can_subscribe` and `can_call` are always true. `can_publish` and `can_serve` do not change (`service_authz/authz/src/acl_policy_model.rs:130-155`). |

**Example.** A service bundle S publishes `TirePressure` on the topic `pressure`. Its policy has one
`Publisher` entry with the type `TirePressure` and the topic `pressure`.

- S also publishes `TirePressure` on a new topic `pressure-rear`. The entry must also name this
  topic, or have `allow_all_topics`. With `allow_all_topics`, a new topic does not change the
  policy.
- S publishes a new message type `BrakeWear`. The policy must have a new entry for it. Thus, the
  APEX of S changes.

**`allow_read_all`** is the widest field. A bundle with this field can subscribe to all message
types and call all service types. It cannot publish or serve more than its entries give. The field
has no limit by type or by topic. No privilege check examines it, because it is in the policy of
the bundle itself. The only control is the key that signs the APEX.

The Telemetry Service of AAOS SDV uses the field. Its full policy is `allow_read_all: true`
(`/apex/com.google.sdv.telemetry/etc/permissions.textproto` on the device).

Thus, a bundle that reads for other bundles can use one field for all types. A bundle that
publishes or serves for other bundles must have an entry for each type.

The platform merges the policy of an SDV package from many files
(`acl_file_provider/src/acl_merger.rs`).

## 3. Start of components

- **Service bundles.** The configuration of the SDV Orchestrator (`*.textproto`, with `started` and
  `retry_mapping`) controls the start, and the start again after an error. A bundle reads its
  configuration when it starts (`on_start`). A change of the policy is an update of the APEX. After
  the update, the bundle starts again.
- **Native programs.** `init` starts a native program from an `.rc` service definition. An APEX
  can contain these service definitions, but no action triggers ([APEX](https://source.android.com/docs/core/ota/apex)).

## 4. SELinux policy outside the APEX

`init` loads the SELinux policy only from the partitions of the system image
([SELinux build](https://source.android.com/docs/security/features/selinux/build)). An APEX has its
own signing key, but it cannot change the policy that limits its code ([APEX](https://source.android.com/docs/core/ota/apex)). Thus, each
SELinux domain of a component in the APEX must be in the image.

| Artefact | Contents | Location |
|---|---|---|
| `*.te` | The domain of each native process and its rules | Image |
| `file_contexts` | The labels of the data directories | Image |
| `property.te`, `property_contexts` | The system properties of the components | Image |
| `file_contexts` of the APEX | The labels of the files in the APEX | APEX, only with types from the image |
