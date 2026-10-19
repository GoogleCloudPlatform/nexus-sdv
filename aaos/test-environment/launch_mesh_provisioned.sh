#!/bin/bash
# Launch the 3-node SDV mesh from images that carry their own per-instance
# bootconfig (baked by bake-instance-bootconfig.sh). No --extra_bootconfig_args:
# identity/virt.address come from each image, avoiding the launch_cvd comma-join
# bug (issue #365, L6a). instance1=IVI(6520), instance2=Core(6521), instance3=3rd(6522).
#
# PREREQUISITE (see plan Task 2 Step 4b): this passes no --config, so launch_cvd
# auto-selects each image's preset via its android-info.txt `config=`. Those
# presets MUST be bootconfig-free per-instance ones — ivi->sdv_ivi_instance1,
# core->sdv_core_instance2, core3->sdv_core_instance3 (the last with its
# extra_bootconfig_args stripped). If an image's android-info.txt points at a
# preset that still carries extra_bootconfig_args (e.g. the stock
# core->sdv_core_instance1), assemble_cvd re-hits the L6a comma-join abort.
set -x
export HOME=/opt/cvd-host-sdv
cd /opt/cvd-host-sdv || exit 1

# preflight: refuse to touch the running mesh if any image would resolve to a
# preset that still carries extra_bootconfig_args (see header note above) -
# that re-triggers the L6a comma-join abort partway through relaunch.
for d in /opt/sdv-images/ivi /opt/sdv-images/core /opt/sdv-images/core3; do
    preset=$(sed -n 's/^config=//p' "$d/android-info.txt")
    cfg="/opt/cvd-host-sdv/etc/cvd_config/cvd_config_${preset}.json"
    if grep -q 'extra_bootconfig_args' "$cfg"; then
        echo "ABORT: $d resolves to preset '$preset' ($cfg), which still has extra_bootconfig_args - fix the preset before launching" >&2
        exit 1
    fi
done

# stop any running mesh + clean stragglers (mirrors deploy_mesh.sh)
./bin/stop_cvd >/dev/null 2>&1 || true
sleep 3
for p in $(pgrep -f "x86_64-linux-gnu/crosvm|process_restarter|run_cvd|log_tee|tombstone_receiver|adb_connector|cf_vhost|openwrt_control|screen_recording"); do kill -9 "$p" 2>/dev/null; done
sleep 2
rm -rf /tmp/vsock_*_1003 /tmp/cf_avd_1003 2>/dev/null || true

nohup ./bin/launch_cvd \
  --daemon \
  --report_anonymous_usage_stats=n \
  --num_instances=3 \
  --system_image_dir=/opt/sdv-images/ivi,/opt/sdv-images/core,/opt/sdv-images/core3 \
  --memory_mb=8192,4096,2096 \
  --cpus=4,4,2 \
  --gpu_mode=auto,none,none \
  --start_webrtc=true,false,false \
  --use_overlay=true \
  --enable_vhal_proxy_server=true,false,false \
  --extra_kernel_cmdline=androidboot.selinux=permissive \
  --use_sdcard=false,false,false \
  --setupwizard_mode=DISABLED,DISABLED,DISABLED \
  --guest_enforce_security=true,true,true \
  --undefok=enable_vhal_proxy_server,start_webrtc,setupwizard_mode,report_anonymous_usage_stats,use_overlay \
  > /opt/cvd-host-sdv/launch_mesh_provisioned.out 2>&1 < /dev/null &
echo "=== launch_cvd started detached, pid $! ==="
