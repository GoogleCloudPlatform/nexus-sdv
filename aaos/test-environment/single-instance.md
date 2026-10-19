# A single AAOS SDV instance

One stock `sdv_core_cf` Cuttlefish instance for the Nexus-Bridge APEX, on a Cuttlefish host (Debian 12, x86_64).

## What the host needs

- Cuttlefish host packages, KVM (`/dev/kvm`, user in group `kvm`), a few GB free.
- SDV host tools in `/opt/cvd-host-sdv/` and an `sdv_core_cf` image in `/opt/sdv-core-image/`, from the same build.

## Image and tools from a mesh host

```bash
# on the mesh host:
tar -C /opt -cf - --exclude=cvd-host-sdv/cuttlefish --exclude='*.log' cvd-host-sdv | \
  ssh <test-host-internal-ip> "sudo tar -xf - -C /opt"
tar -C /opt/sdv-images -cf - core3 | \
  ssh <test-host-internal-ip> "mkdir -p /tmp/img && tar -xf - -C /tmp/img"
# on the test host:
sudo mv /tmp/img/core3 /opt/sdv-core-image
sudo chown -R "$USER":"$USER" /opt/sdv-core-image /opt/cvd-host-sdv
cp /opt/sdv-core-image/android-info.txt.orig /opt/sdv-core-image/android-info.txt
cp /opt/sdv-core-image/vendor_boot.img.orig  /opt/sdv-core-image/vendor_boot.img    # if present
```

## Launch, on clean data

```bash
sudo systemctl stop sdvcore 2>/dev/null; sudo systemctl reset-failed sdvcore 2>/dev/null
pkill -9 -f 'crosvm|run_cvd' 2>/dev/null
rm -rf /opt/cvd-host-sdv/cuttlefish /tmp/cf_avd_* /tmp/vsock_* 2>/dev/null

sudo systemd-run --unit=sdvcore --uid="$USER" --gid="$USER" \
  -E HOME=/opt/cvd-host-sdv -p WorkingDirectory=/opt/cvd-host-sdv \
  /opt/cvd-host-sdv/bin/launch_cvd --report_anonymous_usage_stats=n \
  --system_image_dir=/opt/sdv-core-image \
  --start_webrtc=false --setupwizard_mode=DISABLED --use_sdcard=false \
  --undefok=setupwizard_mode,report_anonymous_usage_stats

until adb -s 0.0.0.0:6520 shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do sleep 10; done
```

Logs: `/opt/cvd-host-sdv/cuttlefish/instances/cvd-1/logs/`.

**Check:** `adb -s 0.0.0.0:6520 shell ls /apex | grep nexus` prints nothing.

## The image must have

```bash
adb -s 0.0.0.0:6520 root
adb -s 0.0.0.0:6520 shell ls /product/etc/brand_new_apex/    # sample.avbpubkey
adb -s 0.0.0.0:6520 shell ls /apex | grep update_manager
```

## Network

- The host masquerades the guest range by itself.
- The guest has no default route; `provision-and-run.sh` sets it (`ip route replace default via 192.168.98.1 dev eth1`).
- The guest has no DNS; the scripts resolve names on the host.

## Single instance and mesh

| | Single instance | Mesh, Core3 |
|---|---|---|
| adb serial | `0.0.0.0:6520` | `0.0.0.0:6522` |
| adb | `adb` on `PATH` | `/opt/cvd-host-sdv/bin/adb` |
| guest address | `192.168.98.3` | `192.168.98.5` |
| leaf address for the head-unit app | — | `192.168.98.5:4222` |

All Nexus modules go onto the one instance; `provision-and-run.sh` finds the serial and adb by itself.
