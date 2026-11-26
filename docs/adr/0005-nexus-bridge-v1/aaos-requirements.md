# Requirements for AAOS

This document gives more information for [ADR-0005](../0005-nexus-bridge-v1.md). Option B4 of the
ADR uses functions that AAOS 17 does not have. This document gives a concept for these functions
and the requirements that follow from it. The concept is a proposal and a base for the
discussion. A different proposal must be equally complete and consistent.

**Overall acceptance criterion:**

- A new service bundle is installed. The APEX of the cloud carrier does not change. The annotated
  items of the new service bundle operate in the four cases of the table below.
- The cloud carrier gets access only to the annotated items. It does not use `allow_read_all`,
  `allow_all_topics` or `allow_all_channels`.
- An item without an annotation does not cross the boundary of the vehicle.
- The platform examines the type of each message that crosses the boundary of the vehicle.

## Concept

### The cloud carrier

The cloud carrier is the bundle that connects the vehicle to the cloud. In Nexus SDV, the cloud
carrier is the Nexus Bridge. The cloud carrier receives messages from the vehicle services and
sends them to the cloud. It also receives messages from the cloud and sends them to the vehicle
services.

### Annotations by the service

The owner of a service bundle annotates each item that can cross the boundary of the vehicle. An
annotation applies to one pair: a message type and its topic, or a service type and its channel. A
topic or a type alone is not sufficient. The direction of the first message sets the annotation:

| Case | Vehicle service | Annotation | The cloud carrier |
|---|---|---|---|
| Publish and subscribe, from the vehicle to the cloud | Publisher | `to-cloud-allowed` | subscribes |
| Publish and subscribe, from the cloud to the vehicle | Subscriber | `from-cloud-accepted` | publishes this type on this topic |
| RPC, the cloud calls the vehicle | Server | `from-cloud-accepted` | calls |
| RPC, the vehicle calls the cloud | Client | `to-cloud-allowed` | serves the channel for the cloud service |

The annotation is part of the signed APEX of the service. Thus, the OEM accepts it when it signs
the service.

### Permission "cloud carrier"

A special permission, "cloud carrier", permits a bundle to use selectors or namespaces for the
annotated items. With this permission, the bundle gets access to the annotated items only, in the
four cases. The platform keeps the type check.

With AAOS 17, a bundle that carries channels for services that it does not know must use wide
permissions such as `allow_all_topics`. Then the platform does not examine the type, and the bundle
must put the messages into a wrapper of its own. The permission "cloud carrier" makes these
workarounds unnecessary.

Nexus SDV has an independent limit on the cloud side. For each vehicle, it decides which cloud
services can send and receive on which channels.

### Integrity of the payload

The integrity check is optional and has two levels:

- **Minimum level: signature at the boundary of the vehicle.** The service sets the check in its
  annotation. From the vehicle to the cloud, the Nexus Bridge signs and Nexus SDV examines the
  signature. From the cloud to the vehicle, Nexus SDV signs and the Nexus Bridge examines the
  signature. The Nexus Bridge uses the identity of the vehicle that it holds for the connection.
  The service has no key and no task.
- **Zero trust: end-to-end signature.** The service signs and examines the signatures with the
  Nexus SDK. The Nexus Bridge and Nexus SDV only forward the messages. The key of the service comes
  from the DICE chain (Device Identifier Composition Engine) of the vehicle. Nexus SDV extends the
  chain to the cloud.

## Requirements

### 1. Annotations

**Today in AAOS 17:** The policy of a service bundle declares its publications, subscriptions,
servers and clients, with type and topic or channel. No field in the policy tells if an item can
cross the boundary of the vehicle.

**Requirement:** A service bundle can annotate a publication or a client as `to-cloud-allowed`,
and a subscription or a server as `from-cloud-accepted`, in its own policy. The annotation applies
to the topic or the channel and to the message type.

**Acceptance criterion:** The platform shows a list of the annotated items in a vehicle, with the
annotation. An item without an annotation is not in this list.

### 2. Permission "cloud carrier"

**Today in AAOS 17:** `allow_read_all` permits a bundle to subscribe to all publications and to
call all services in the vehicle. To publish and to serve, a bundle must use `allow_all_topics` or
`allow_all_channels`. Then the platform does not examine the type.

**Requirement:** A permission "cloud carrier" permits a bundle to subscribe, publish, call and
serve only the annotated items, as the table in the concept shows. The platform examines the type
of each message. Only a bundle that has the permission in its signed policy gets this access.

**Acceptance criterion:**

- The cloud carrier publishes the annotated type on a topic with `from-cloud-accepted`, and the
  publication operates. A publication of a different type on this topic fails.
- The cloud carrier subscribes to a publication without an annotation, and the platform refuses
  the subscription.
- A bundle without the permission gets no access to the annotated items.

### 3. Discovery while the cloud carrier operates

**Today in AAOS 17:** A bundle gets its permissions at its start.

**Requirement:** The cloud carrier gets the annotated items of a new service bundle while it
operates. It does not start again for this.

**Acceptance criterion:** A new service bundle is installed while the cloud carrier operates. The
cloud carrier gets the annotated items of the new service bundle, and the channels operate. The
cloud carrier does not start again.

### 4. Signature at the boundary of the vehicle

**Today in AAOS 17:** The policy has no field for an integrity check.

**Requirement:** The annotation of an item can also request a signature. The platform gives this
request to the cloud carrier, together with the annotated item.

**Acceptance criterion:** The cloud carrier gets the signature request of an annotated item. An
item without the request has no signature.

### 5. Key for each service bundle from the DICE chain

**Today in AAOS 17:** Not examined.

**Requirement:** Each service bundle can get its own signature key. The key comes from the DICE
chain of the vehicle. A certificate shows the position of the key in the chain.

**Acceptance criterion:** A service bundle signs a message with its key. A receiver in the cloud
examines the signature and the certificate chain to the root of the vehicle.

## Functions on the Nexus SDV side

These functions are not requirements for AAOS. They complete the concept:

- The Nexus Bridge signs and examines messages at the boundary of the vehicle, with the identity
  of the vehicle (requirement 4).
- Nexus SDV signs and examines messages on the cloud side (requirement 4).
- The Nexus SDK signs and examines end-to-end signatures in the service (requirement 5).
- The factory process records the root of the DICE chain of each vehicle. Nexus SDV examines the
  chain to this root (requirement 5).
