#!/usr/bin/env bash
# Starts the three-node mesh after the host VM was started, on the disks it had: the host's
# forwarding, the launch, the wait for all three guests, the default route on the guest
# that holds the connectivity, and a report of each guest. What was installed and
# provisioned before survives; the samples are started as in aaos/INSTALL.md, part 4.2.
#
# Run on the Cuttlefish host, as a user that may use sudo:
#   ./mesh-start.sh
#
# Environment, all optional:
#   NEXUS_ADB           the adb on the host (default /opt/cvd-host-sdv/bin/adb)
#   NEXUS_GUESTS        the guests' serials (default "0.0.0.0:6520 0.0.0.0:6521 0.0.0.0:6522")
#   NEXUS_CONNECTIVITY  the guest that holds the connectivity (default 0.0.0.0:6522)
#   NEXUS_LAUNCH        the launch command (default: launch_mesh_provisioned.sh beside this
#                       script, as the user cvd)
#   NEXUS_BOOT_WAIT     seconds to wait for each guest (default 300)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="${NEXUS_ADB:-/opt/cvd-host-sdv/bin/adb}"
GUESTS="${NEXUS_GUESTS:-0.0.0.0:6520 0.0.0.0:6521 0.0.0.0:6522}"
CONNECTIVITY="${NEXUS_CONNECTIVITY:-0.0.0.0:6522}"
LAUNCH="${NEXUS_LAUNCH:-sudo -u cvd -H bash -c 'cd /opt/cvd-host-sdv && HOME=/opt/cvd-host-sdv $HERE/launch_mesh_provisioned.sh'}"
BOOT_WAIT="${NEXUS_BOOT_WAIT:-300}"
POLL="${NEXUS_POLL:-4}"
SUBNET=192.168.98.0/24
GATEWAY=192.168.98.1
[[ "$BOOT_WAIT" =~ ^[0-9]+$ ]] || { echo "NEXUS_BOOT_WAIT must be a whole number of seconds" >&2; exit 2; }

fail() { echo "✗ $1" >&2; exit 1; }

echo "=== Forwarding on the host ==="
# Lost whenever the host VM stops; Docker on this host sets the FORWARD policy to DROP.
# Each rule is added only when it is missing, so a second run changes nothing.
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || fail "could not enable forwarding"
sudo iptables -t nat -C POSTROUTING -s "$SUBNET" ! -o cvd-ebr -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s "$SUBNET" ! -o cvd-ebr -j MASQUERADE \
    || fail "could not add the NAT rule"
sudo iptables -C FORWARD -i cvd-ebr -j ACCEPT 2>/dev/null \
    || sudo iptables -I FORWARD 1 -i cvd-ebr -j ACCEPT \
    || fail "could not add the outbound FORWARD rule"
sudo iptables -C FORWARD -o cvd-ebr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -I FORWARD 2 -o cvd-ebr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
    || fail "could not add the return FORWARD rule"
echo "  forwarding for $SUBNET in place"

echo "=== Launch ==="
bash -c "$LAUNCH" || fail "the launch command failed: $LAUNCH"

echo "=== Waiting for the guests (up to ${BOOT_WAIT}s each) ==="
for s in $GUESTS; do
    waited=0
    until [ "$($ADB -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
        [ "$waited" -ge "$BOOT_WAIT" ] && fail "$s did not finish booting within ${BOOT_WAIT}s"
        $ADB connect "$s" >/dev/null 2>&1
        sleep "$POLL"; waited=$((waited + POLL))
    done
    echo "  $s booted"
done

echo "=== Default route on $CONNECTIVITY ==="
# The guest loses it at every boot; without it the vehicle does not reach the cloud.
$ADB -s "$CONNECTIVITY" root >/dev/null 2>&1
sleep 2
$ADB connect "$CONNECTIVITY" >/dev/null 2>&1
$ADB -s "$CONNECTIVITY" shell ip route replace default via "$GATEWAY" dev eth1 >/dev/null 2>&1
route="$($ADB -s "$CONNECTIVITY" shell ip route 2>/dev/null | tr -d '\r' | grep '^default')"
[[ "$route" == "default via $GATEWAY"* ]] || fail "no default route via $GATEWAY on $CONNECTIVITY (got: ${route:-none})"
echo "  $route"

echo "=== The guests ==="
for s in $GUESTS; do
    name="$($ADB -s "$s" shell getprop ro.boot.sdv.instance_name 2>/dev/null | tr -d '\r')"
    build="$($ADB -s "$s" shell getprop ro.build.date 2>/dev/null | tr -d '\r')"
    echo "-- $s ${name:-?} (image of ${build:-?})"
    $ADB -s "$s" shell 'ls /apex | grep nexus | grep @; ps -AZ | grep -E "nexus|nats-server"' 2>/dev/null \
        | tr -d '\r' | sed 's/^/   /'
done
echo "✓ mesh up — start the samples as in aaos/INSTALL.md, part 4.2"
