#!/usr/bin/env bash
# Starts Google's sample publisher — the source of the random speed in the telemetry
# reports — on the VM that runs the nexus-telemetry-client, and makes sure it stays up.
#
#   ADB="adb -s 0.0.0.0:6522" ./start-sample-publisher.sh
#
# Why a script for one command: the publisher (/vendor/bin/telemetry_sample_publisher)
# aborts when a metrics configuration already waits for it — "there is no reactor running,
# must be called from the context of a Tokio 1.x runtime" — and the nexus-telemetry-client,
# started at boot, is always there first. So the client is stopped, the publisher started
# until it stays (on 2026-10-16 the fourth start did), and the client started again.
# Nothing starts the publisher by itself, so this is needed after every boot of that VM.
set -u
ADB="${ADB:?set ADB, e.g. ADB=\"adb -s 0.0.0.0:6522\"}"
TRIES="${PUBLISHER_START_TRIES:-6}"
WAIT="${PUBLISHER_START_WAIT:-6}"

running() { [ -n "$(${ADB} shell pidof telemetry_sample_publisher 2>/dev/null | tr -dc '0-9 ')" ]; }

ROUNDS="${PUBLISHER_ROUNDS:-3}"

if running; then echo "✓ the sample publisher is already running"; exit 0; fi
for round in $(seq 1 "$ROUNDS"); do
    [ "$round" -gt 1 ] && echo "round $round: the publisher did not survive the client's start — again"
    ${ADB} shell stop nexus_telemetry_client
    up=""
    for try in $(seq 1 "$TRIES"); do
        ${ADB} shell 'setsid nohup /vendor/bin/telemetry_sample_publisher >/dev/null 2>&1 </dev/null &'
        sleep "$WAIT"
        if running; then up="$try"; break; fi
        echo "  start $try: it did not stay up — trying again"
    done
    ${ADB} shell start nexus_telemetry_client
    if [ -z "$up" ]; then
        echo "✗ the sample publisher did not stay up after $TRIES starts" >&2
        echo "  why: ${ADB} logcat -d | grep -E 'TelemetrySamplConfigPub|Abort message'" >&2
        exit 1
    fi
    # The client's start activates its metrics configuration, which can still bring the
    # publisher down (seen on Core3, 2026-10-16): look again once the client runs.
    sleep "$WAIT"
    if running; then
        echo "✓ the sample publisher is running (start $up of $TRIES, round $round); the telemetry client is started again"
        exit 0
    fi
done
echo "✗ the sample publisher did not survive the client's start, $ROUNDS rounds" >&2
echo "  why: ${ADB} logcat -d | grep -E 'TelemetrySamplConfigPub|Abort message'" >&2
exit 1
