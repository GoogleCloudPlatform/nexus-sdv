#!/usr/bin/env bash
# Fetches the linux-amd64 nats-server release matching whatever version is
# ACTUALLY running on the target Nexus cloud right now. The version is read
# from the NATS INFO banner on the client port — plain TCP, no gcloud/kubectl,
# so this works for external parties too (the GKE control plane is not
# reachable from arbitrary workstations anyway).
#
# Usage: ./fetch-nats-server.sh <nats-host> [port]
#   nats-host: the hub of the Nexus instance the vehicle will connect to, nats.<base-domain>
#   port:      4222 unless given
set -euo pipefail
NATS_HOST="${1:?usage: fetch-nats-server.sh <nats-host> [port] — the hub of your Nexus instance, nats.<base-domain>}"
NATS_PORT="${2:-4222}"

INFO="$(nc -w 5 "$NATS_HOST" "$NATS_PORT" < /dev/null | head -c 512 || true)"
VERSION="$(echo "$INFO" | sed -n 's/.*"version":"\([0-9.]*\)".*/\1/p')"
[ -n "$VERSION" ] || { echo "could not read a version from ${NATS_HOST}:${NATS_PORT} INFO banner" >&2; exit 1; }
echo "Live Nexus NATS version: ${VERSION} (${NATS_HOST}:${NATS_PORT})"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
curl -fL --max-time 120 -o /tmp/nats-server.tar.gz \
  "https://github.com/nats-io/nats-server/releases/download/v${VERSION}/nats-server-v${VERSION}-linux-amd64.tar.gz"
tar -xzf /tmp/nats-server.tar.gz -C /tmp "nats-server-v${VERSION}-linux-amd64/nats-server"
cp "/tmp/nats-server-v${VERSION}-linux-amd64/nats-server" "${SCRIPT_DIR}/prebuilt-nats-server"
chmod +x "${SCRIPT_DIR}/prebuilt-nats-server"
echo "Fetched to ${SCRIPT_DIR}/prebuilt-nats-server"
