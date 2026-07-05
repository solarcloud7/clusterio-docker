#!/bin/bash
# regenerate-export-data.sh — refresh the web UI's icon/prototype export.
#
# Run this after ANY Factorio/client/mod-pack version change: the seed-time
# auto-export runs once per first boot only, so a version bump otherwise ships
# blank "?" icons until someone remembers this sequence (docs/asset-export.md).
#
# Usage (inside the controller container):
#   docker exec clusterio-controller /scripts/regenerate-export-data.sh <instance-name>
#
# The instance must live on a host with the full game client (see EXPORT_HOST).
set -eo pipefail

INSTANCE="${1:?usage: regenerate-export-data.sh <instance-name>}"
CONTROL_CONFIG="${CONTROL_CONFIG:-/clusterio/tokens/config-control.json}"

ctl() {
  gosu clusterio npx clusterioctl --log-level error "$@" --config "$CONTROL_CONFIG"
}

echo "Stopping '$INSTANCE' for export-data..."
ctl instance stop "$INSTANCE" 2>/dev/null || true
sleep 5

echo "Running export-data on '$INSTANCE' (requires the game client on its host)..."
tries=0
until ctl instance export-data "$INSTANCE"; do
  tries=$((tries + 1))
  if [ "$tries" -ge 6 ]; then
    echo "ERROR: export-data failed after $tries attempts — is the game client installed on this instance's host? (docs/asset-export.md)" >&2
    echo "Restarting '$INSTANCE' anyway..."
    ctl instance start "$INSTANCE" 2>/dev/null || true
    exit 1
  fi
  echo "  not ready yet, retrying in 10s... ($tries/6)"
  sleep 10
done
echo "Export complete."

echo "Restarting '$INSTANCE'..."
ctl instance start "$INSTANCE" 2>/dev/null || true
echo "Done — the web UI serves the refreshed assets."
