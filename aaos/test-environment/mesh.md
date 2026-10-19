# The three-node mesh

Three Cuttlefish instances on one host: IVI, Core and Core3.

| Role | adb serial | instance | `virt.address` | guest address |
|---|---|---|---|---|
| IVI | `0.0.0.0:6520` | instance1 | 3 | 192.168.98.3 |
| Core | `0.0.0.0:6521` | instance2 | 4 | 192.168.98.4 |
| Core3, connectivity | `0.0.0.0:6522` | instance3 | 5 | 192.168.98.5 |

adb: `/opt/cvd-host-sdv/bin/adb`. Head-unit screen: `https://localhost:8443` through `ssh -L 8443:localhost:8443`.

## Phases

| # | Phase | Script |
|---|---|---|
| 1 | Cuttlefish host packages and the SDV host tools in `/opt/cvd-host-sdv/` | — |
| 2 | Images in `/opt/sdv-images/{ivi,core}` | — |
| 3 | Each instance's identity baked into its `vendor_boot.img` | `bake-instance-bootconfig.sh`, `install-images.sh` |
| 4 | Launch | `mesh-start.sh` |

Phases 1 to 3 persist on disk; after every start of the host only phase 4.

## Phase 1 — host

Cuttlefish host packages from `deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main` (1.55.0), then a reboot. The mesh launches with `/opt/cvd-host-sdv/bin/launch_cvd`, not the package's `cvd`.

## Phase 2 — images

`/opt/sdv-images/ivi` and `/opt/sdv-images/core`, from an AOSP build or copied from another mesh host ([single-instance.md](single-instance.md)), together with `/opt/cvd-host-sdv/` from the same build. Images are never committed.

## Phase 3 — identity

Each image carries its identity in `vendor_boot.img`; the launch passes none.

```bash
# instance1 — IVI, with the leaf line for the head-unit app
/opt/cvd-host-sdv/bake-instance-bootconfig.sh /opt/sdv-images/ivi \
  "androidboot.sdv.instance_name=instance1 androidboot.virt.address=3 androidboot.sdv.init_open_dice.sample_file=dice_handover_instance1 androidboot.sdv.keymint.rpc.hbk=799da7577efd41d5b27810c5952fcec0291cbcfd687e77ac9a6cec8370651b1d androidboot.sdv.boot_mode=locked androidboot.sdv.vvmfactorytrust=c779a73d0595a6814ba0414a419e99ad4026ad0feb603f2ad80ee6a9e4d1adb7 androidboot.sdv.preprovisioned_vvmtruststore=img androidboot.sdv.ignore_avb_state=true androidboot.nexus.leaf=192.168.98.5:4222"

# instance2 — Core
/opt/cvd-host-sdv/bake-instance-bootconfig.sh /opt/sdv-images/core \
  "androidboot.sdv.instance_name=instance2 androidboot.virt.address=4 androidboot.sdv.init_open_dice.sample_file=dice_handover_instance2 androidboot.sdv.keymint.rpc.hbk=a3b876291ff7341d861e325406b96a0b58d0a3daf6b030681b8afc24b84d1160 androidboot.sdv.boot_mode=locked androidboot.sdv.vvmfactorytrust=c779a73d0595a6814ba0414a419e99ad4026ad0feb603f2ad80ee6a9e4d1adb7 androidboot.sdv.preprovisioned_vvmtruststore=img androidboot.sdv.ignore_avb_state=true"

# instance3 — Core3, a copy of Core
rm -rf /opt/sdv-images/core3
cp -a /opt/sdv-images/core /opt/sdv-images/core3
rm -f  /opt/sdv-images/core3/vendor_boot.img.orig
cp -f  /opt/sdv-images/core/vendor_boot.img.orig /opt/sdv-images/core3/vendor_boot.img
/opt/cvd-host-sdv/bake-instance-bootconfig.sh /opt/sdv-images/core3 \
  "androidboot.sdv.instance_name=instance3 androidboot.virt.address=5 androidboot.sdv.init_open_dice.sample_file=dice_handover_instance3 androidboot.sdv.keymint.rpc.hbk=c1e9daeff3917170e81ea6fe9157ebbc95982462b6c7e622082c22db71972e83 androidboot.sdv.boot_mode=locked androidboot.sdv.vvmfactorytrust=c779a73d0595a6814ba0414a419e99ad4026ad0feb603f2ad80ee6a9e4d1adb7 androidboot.sdv.preprovisioned_vvmtruststore=img androidboot.sdv.ignore_avb_state=true"
```

Point the presets at the right instances and take the boot lines out of Core3's:

```bash
for m in core:sdv_core_instance2 core3:sdv_core_instance3; do
  d=${m%:*}; want=${m#*:}
  cp -n /opt/sdv-images/$d/android-info.txt /opt/sdv-images/$d/android-info.txt.orig
  sed -i "s/^config=.*/config=$want/" /opt/sdv-images/$d/android-info.txt
done
P=/opt/cvd-host-sdv/etc/cvd_config/cvd_config_sdv_core_instance3.json
cp -n "$P" "$P.orig"
python3 -c "import json; p='$P'; d=json.load(open(p)); d.pop('extra_bootconfig_args',None); json.dump(d,open(p,'w'),indent=2)"
```

**Check:**

```bash
for d in ivi:3 core:4 core3:5; do
  dir=${d%:*}; want=${d#*:}
  rm -rf /tmp/c
  /opt/cvd-host-sdv/bin/unpack_bootimg --boot_img /opt/sdv-images/$dir/vendor_boot.img --out /tmp/c >/dev/null
  echo "$dir: $(grep -oE 'virt.address=[0-9]+' /tmp/c/bootconfig | head -1) (want virt.address=$want)"
done; rm -rf /tmp/c
```

### A new image set

```bash
sudo ./install-images.sh /opt/sdv-images-new core=sdv_core_instance2 core3=sdv_core_instance3
```

It keeps the previous set as `<instance>.prev-<time>`; remove old ones, the launch needs about 8.5 GB free for the IVI's data. Launch on fresh disks afterwards:

```bash
sed 's/--daemon \\/--daemon \\\n  --resume=false \\/' launch_mesh_provisioned.sh > /tmp/launch_mesh_fresh.sh
NEXUS_LAUNCH="sudo -u cvd -H bash -c 'cd /opt/cvd-host-sdv && HOME=/opt/cvd-host-sdv /tmp/launch_mesh_fresh.sh'" ./mesh-start.sh
```

## Phase 4 — launch

In `aaos/test-environment` on the host:

```bash
./mesh-start.sh
# ✓ mesh up — start the samples as in aaos/INSTALL.md, part 4.2
```

It sets the host's forwarding, launches through `launch_mesh_provisioned.sh`, waits for all three guests, sets Core3's default route and reports each guest.

## Notes

- Guests boot SELinux permissive and with `sdv.authz.enable=true`.
- Core has no default route; host services are at `192.168.98.1`.
- The guests' `sh` has no `/dev/tcp` and no `awk`.
- Check nested virtualization if guests do not launch: `gcloud compute instances describe … --format="value(advancedMachineFeatures.enableNestedVirtualization)"`.
