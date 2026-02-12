#!/bin/bash
# seed-instances.sh
# Creates, assigns, configures, uploads saves, and optionally starts seeded instances.
#
# Expected environment / arguments:
#   $1 = CONTROL_CONFIG  (path to config-control.json)
#   $2 = HOST_COUNT      (number of expected hosts)
#
# Reads from: /clusterio/seed-data/hosts/<hostname>/<instance>/
#   - *.zip          → uploaded as saves
#   - instance.json  (optional) → native Clusterio instance config
#
# instance.json is the standard Clusterio InstanceConfig format. Fields that
# are environment-specific (IDs, tokens, assigned host) are automatically
# skipped. All other fields are applied via `clusterioctl instance config set`.

set -e

CONTROL_CONFIG="$1"
HOST_COUNT="${2:-0}"
SEED_DATA_DIR="/clusterio/seed-data"

# Fields that must NOT be seeded — they are runtime/environment-specific
SKIP_FIELDS=(
  "instance.id"
  "instance.name"
  "instance.assigned_host"
  "factorio.host_assigned_game_port"
  "factorio.rcon_port"
  "factorio.rcon_password"
  "factorio.mod_pack_id"
)

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
    # Count data rows where the 'connected' column is 'true' (skip header row)
    connected=$(gosu clusterio npx clusterioctl --log-level error host list \
      --config "$CONTROL_CONFIG" 2>/dev/null | grep -c "| true " || true)
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
# Check if a field should be skipped
# ---------------------------------------------------------------------------
should_skip_field() {
  local field="$1"
  for skip in "${SKIP_FIELDS[@]}"; do
    if [ "$field" = "$skip" ]; then
      return 0
    fi
  done
  # Skip internal Clusterio metadata
  if [ "$field" = "_warning" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Apply instance.json configuration
# ---------------------------------------------------------------------------
apply_instance_config() {
  local instance_name="$1"
  local config_file="$2"
  local applied=0

  echo "      Applying instance.json configuration..."

  # Extract all top-level keys and their values from instance.json
  # Uses a simple line-by-line approach for flat keys and JSON for objects
  while IFS= read -r line; do
    # Match "key": value lines (top-level only, not nested inside objects)
    local field value
    field=$(echo "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:.*/\1/p')

    if [ -z "$field" ]; then
      continue
    fi

    if should_skip_field "$field"; then
      continue
    fi

    # Extract the value — handle objects (factorio.settings) specially
    # Use python/node to properly extract JSON values
    value=$(gosu clusterio node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('$config_file', 'utf8'));
      const val = cfg['$field'];
      if (val === null || val === undefined) {
        process.stdout.write('');
      } else if (typeof val === 'object') {
        process.stdout.write(JSON.stringify(val));
      } else {
        process.stdout.write(String(val));
      }
    " 2>/dev/null) || continue

    if [ -z "$value" ]; then
      continue
    fi

    gosu clusterio npx clusterioctl --log-level error instance config set \
      "$instance_name" "$field" "$value" \
      --config "$CONTROL_CONFIG" 2>/dev/null || {
        echo "        Warning: Failed to set $field"
        continue
      }
    applied=$((applied + 1))
  done < "$config_file"

  echo "      Applied $applied config field(s)"
}

# ---------------------------------------------------------------------------
# Seed a single instance
# ---------------------------------------------------------------------------
seed_instance() {
  local instance_dir="$1"
  local host_id="$2"
  local instance_name
  instance_name=$(basename "$instance_dir")

  # Idempotency check: skip if instance with this name already exists
  local existing
  existing=$(gosu clusterio npx clusterioctl --log-level error instance list \
    --config "$CONTROL_CONFIG" 2>/dev/null | grep -F " $instance_name " || true)

  if [ -n "$existing" ]; then
    echo "    Instance '$instance_name' already exists — skipping"
    return 0
  fi

  echo "    Creating instance: $instance_name"

  # Create the instance
  gosu clusterio npx clusterioctl --log-level error instance create "$instance_name" \
    --config "$CONTROL_CONFIG" 2>/dev/null || true

  # Assign to host
  echo "      Assigning to host $host_id"
  gosu clusterio npx clusterioctl --log-level error instance assign "$instance_name" "$host_id" \
    --config "$CONTROL_CONFIG" 2>/dev/null || true

  # Apply instance.json configuration (if present)
  if [ -f "${instance_dir}instance.json" ]; then
    apply_instance_config "$instance_name" "${instance_dir}instance.json"
  fi

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

  # Determine auto_start from instance.json (default: true)
  local auto_start=true
  if [ -f "${instance_dir}instance.json" ]; then
    local parsed
    parsed=$(gosu clusterio node -e "
      const cfg = JSON.parse(require('fs').readFileSync('${instance_dir}instance.json', 'utf8'));
      process.stdout.write(String(cfg['instance.auto_start'] ?? true));
    " 2>/dev/null) || true
    if [ "$parsed" = "false" ]; then
      auto_start=false
    fi
  fi

  if [ "$auto_start" = "true" ]; then
    echo "      Starting instance: $instance_name"
    gosu clusterio npx clusterioctl --log-level error instance start "$instance_name" \
      --config "$CONTROL_CONFIG" 2>/dev/null || true
  else
    echo "      Skipping auto-start (instance.auto_start=false)"
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
