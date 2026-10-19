# NATS cluster

This Helm chart provides all necessary resources for deploying a NATS messaging cluster. The `values.yaml` file outlines the general configuration options.

## Mandatory variables
- **config.merge.authorization.users[0].user**
  - username of the NATS basic auth

## Mandatory secrets
- **config.merge.authorization.users[0].password**
  - password of the NATS basic auth
- **config.merge.authorization.auth_callout.issuer**
  - the public key of the nkey issuing keypair

## The store's disk

The hub keeps the Cloud Service Registry's buckets on one persistent disk
(`config.jetstream.fileStore.pvc` in `values.yaml`): storage class `dynamic-rwo`, 4 GiB.
`dynamic-rwo` is GKE's own class; it creates the disk type the node accepts. The class is
named and not left to the cluster's default because the default creates `pd-balanced` disks,
which the arm64 nodes Autopilot provides do not attach; `dynamic-rwo` creates a Hyperdisk
there and a Persistent Disk elsewhere, and 4 GiB is the smallest size Hyperdisk Balanced offers
([About Hyperdisk for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/hyperdisk)).

`tests/store-volume.test.sh` renders the helmfile for both architectures and checks the claim.

### Deploying onto a platform that still has the old disk

Until 2026-10-08 the claim named no class and asked for 2 GiB. Kubernetes does not change
the claim of an existing StatefulSet, and the deploy pipeline does not replace it. On such a
platform the deploy fails at the StatefulSet (`spec: Forbidden: updates to statefulset spec …`),
or — on arm64 — `nats-0` stays in `ContainerCreating` with `pd-balanced disk type cannot be
used by …`. Delete both objects, then deploy NATS again:

```bash
kubectl -n base-services delete statefulset nats
kubectl -n base-services delete pvc nats-js-nats-0
```

The store starts empty. Nothing has to be restored by hand: the cloud services register
again, and the vehicles announce their offers again when their leaf link comes back.

