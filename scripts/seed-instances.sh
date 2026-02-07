#!/bin/bash
# seed-instances.sh
# Creates, assigns, uploads saves, and optionally starts seeded instances.
#
# Expected environment / arguments:
#   $1 = CONTROL_CONFIG  (path to config-control.json)
#   $2 = HOST_COUNT      (number of expected hosts)
#
# Reads from: /clusterio/seed-data/hosts/<hostname>/<instance>/
#   - *.zip   → uploaded as saves
#   - config.json (optional) → per-instance settings
#       { "auto_start": true }   ← start instance after seeding (default: true)

set -e

CONTROL_CONFIG="$1"
HOST_COUNT="${2:-0}"
SEED_DATA_DIR="/clusterio/seed-data"

if [ ! -d "$SEED_DATA_DIR/hosts" ]; then
  echo "No seed-data/hosts directory found, skipping instance seeding."
  exit 0
fi

# ---------------------------------------------------------------------------
# Wait for all hosts to connect
# ---------------------------------------------------------------------------
wait_for_hosts() {
  local expected="$1"
  local max_attempts=30

  if [ "$expected" -le 0 ]; then
    return 0
  fi

  echo "Waiting for $expected host(s) to connect..."
  for i in $(seq 1 "$max_attempts"); do
    local connected
    connected=$(gosu clusterio npx clusterioctl --log-level error host list \
      --config "$CONTROL_CONFIG" 2>/dev/null | grep -c "connected" || true)
    connected=${connected:-0}

    if [ "$connected" -ge "$expected" ]; then
      echo "All hosts connected"
      return 0
    fi
    sleep 2
  done

  echo "WARNING: Only $connected of $expected host(s) connected after waiting"
}

# ---------------------------------------------------------------------------
# Seed a single instance
# ---------------------------------------------------------------------------
seed_instance() {
  local instance_dir="$1"
  local host_id="$2"
  local instance_name
  instance_name=$(basename "$instance_dir")

  echo "    Creating instance: $instance_name"

  # Create the instance
  gosu clusterio npx clusterioctl --log-level error instance create "$instance_name" \
    --config "$CONTROL_CONFIG" 2>/dev/null || true

  # Assign to host
  echo "      Assigning to host $host_id"
  gosu clusterio npx clusterioctl --log-level error instance assign "$instance_name" "$host_id" \
    --config "$CONTROL_CONFIG" 2>/dev/null || true

  # Upload save files (.zip)
  for save_file in "${instance_dir}"*.zip; do
    if [ -f "$save_file" ]; then
      local save_name
      save_name=$(basename "$save_file")
      echo "      Uploading save: $save_name"
      gosu clusterio npx clusterioctl --log-level error instance save upload "$instance_name" "$save_file" \
        --config "$CONTROL_CONFIG" 2>/dev/null || true
    fi
  done

  # Read per-instance config (default: auto_start=true)
  local auto_start=true
  if [ -f "${instance_dir}config.json" ]; then
    # Parse auto_start from config.json (defaults to true if missing)
    local parsed
    parsed=$(grep -oP '"auto_start"\s*:\s*\K(true|false)' "${instance_dir}config.json" 2>/dev/null || echo "true")
    auto_start="$parsed"
  fi

  if [ "$auto_start" = "true" ]; then
    echo "      Starting instance: $instance_name"
    gosu clusterio npx clusterioctl --log-level error instance start "$instance_name" \
      --config "$CONTROL_CONFIG" 2>/dev/null || true
  else
    echo "      Skipping auto-start (auto_start=false in config.json)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
wait_for_hosts "$HOST_COUNT"

echo "Processing seed data..."
for host_dir in "$SEED_DATA_DIR/hosts"/*/; do
  if [ ! -d "$host_dir" ]; then
    continue
  fi

  host_name=$(basename "$host_dir")
  # Extract host ID from folder name (e.g., clusterio-host-1 -> 1)
  host_id=$(echo "$host_name" | grep -oE '[0-9]+$' || echo "")

  if [ -z "$host_id" ]; then
    echo "  Warning: Could not extract host ID from '$host_name', skipping"
    continue
  fi

  echo "  Processing host: $host_name (ID: $host_id)"

  for instance_dir in "$host_dir"*/; do
    if [ -d "$instance_dir" ]; then
      seed_instance "$instance_dir" "$host_id"
    fi
  done
done

echo "Instance seeding complete."
