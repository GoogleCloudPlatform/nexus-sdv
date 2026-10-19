# test-environment

Tools for maintaining Cuttlefish hosts and instances.

| Guide | Contents |
|---|---|
| [single-instance.md](single-instance.md) | one `sdv_core_cf` instance |
| [mesh.md](mesh.md) | three instances: IVI, Core, Core3 |
| [comms-manual-testing.md](comms-manual-testing.md) | the Data Tunnel by hand, with `sdv_comms_client_rs` |
| [nats-manual-testing.md](nats-manual-testing.md) | subscribing at the hub with the `nats` command line |

| Script | Contents |
|---|---|
| [`mesh-start.sh`](mesh-start.sh) | starts the mesh after the host VM started: forwarding, launch, wait, route on Core3, report |
| [`install-images.sh`](install-images.sh) | installs a new image set and bakes each instance's boot lines into it |
| [`bake-instance-bootconfig.sh`](bake-instance-bootconfig.sh) | bakes boot lines into one image; called by `install-images.sh` |
| [`launch_mesh_provisioned.sh`](launch_mesh_provisioned.sh) | launches the three instances; called by `mesh-start.sh` |

Tests, without a host: `tests/mesh-start.test.sh`, `tests/install-images.test.sh`.
