#!/bin/bash
# controller-entrypoint.sh
set -e

DATA_DIR="/clusterio/data"
CONFIG_PATH="$DATA_DIR/config-controller.json"
TOKENS_DIR="/clusterio/tokens"
EXTERNAL_PLUGINS_DIR="/clusterio/external_plugins"
SEED_DATA_DIR="/clusterio/seed-data"

# Create data directory and fix permissions
mkdir -p "$DATA_DIR" "$TOKENS_DIR"
chown -R clusterio:clusterio "$DATA_DIR" "$TOKENS_DIR"

# Handle external plugins if mounted
source /scripts/install-plugins.sh
install_external_plugins "$EXTERNAL_PLUGINS_DIR"

# Check if first run (no config file yet)
FIRST_RUN=false
if [ ! -f "$CONFIG_PATH" ]; then
  FIRST_RUN=true
  echo "First run detected, configuring controller..."
  
  # Seed database files from seed-data/controller/database/ BEFORE any config
  if [ -d "$SEED_DATA_DIR/controller/database" ]; then
    echo "Seeding database files..."
    mkdir -p "$DATA_DIR/database"
    for db_file in "$SEED_DATA_DIR/controller/database"/*.json; do
      if [ -f "$db_file" ]; then
        filename=$(basename "$db_file")
        # Skip example files
        if [[ "$filename" != *.example.json ]]; then
          echo "  Copying: $filename"
          cp "$db_file" "$DATA_DIR/database/$filename"
        fi
      fi
    done
    chown -R clusterio:clusterio "$DATA_DIR/database"
  fi
  
  # Configure paths relative to data volume
  gosu clusterio npx clusteriocontroller --log-level error config set controller.database_directory "$DATA_DIR/database" --config "$CONFIG_PATH"
  gosu clusterio npx clusteriocontroller --log-level error config set controller.http_port "${CONTROLLER_HTTP_PORT:-8080}" --config "$CONFIG_PATH"
  if [ -n "$CONTROLLER_PUBLIC_ADDRESS" ]; then
    gosu clusterio npx clusteriocontroller --log-level error config set controller.public_address "$CONTROLLER_PUBLIC_ADDRESS" --config "$CONFIG_PATH"
  fi

  # --- Bootstrap (must run BEFORE controller starts) ---
  # These commands modify database files on disk. The controller loads them
  # into memory at startup, so they must be written before `controller run`.

  if [ -z "$INIT_CLUSTERIO_ADMIN" ]; then
    echo "ERROR: INIT_CLUSTERIO_ADMIN is not set. Cannot create admin user."
    echo "       Set it in controller.env or as an environment variable."
    exit 1
  fi

  # Only create admin if not already present in seeded database
  if [ -f "$DATA_DIR/database/users.json" ] && grep -q "\"name\":.*\"$INIT_CLUSTERIO_ADMIN\"" "$DATA_DIR/database/users.json"; then
    echo "Admin user '$INIT_CLUSTERIO_ADMIN' found in seeded database — skipping bootstrap create-admin"
  else
    echo "Creating admin user: $INIT_CLUSTERIO_ADMIN"
    gosu clusterio npx clusteriocontroller --log-level error bootstrap create-admin "$INIT_CLUSTERIO_ADMIN" --config "$CONFIG_PATH"
  fi

  # Generate control config (token) for API access
  CONTROL_CONFIG="$TOKENS_DIR/config-control.json"
  echo "Generating control config for API access..."
  gosu clusterio npx clusteriocontroller --log-level error bootstrap create-ctl-config "$INIT_CLUSTERIO_ADMIN" --config "$CONFIG_PATH"
  mv /clusterio/config-control.json "$CONTROL_CONFIG"
  
  # Generate host tokens if HOST_COUNT is set (default: 0 for standalone usage)
  HOST_COUNT=${HOST_COUNT:-0}
  if [ "$HOST_COUNT" -gt 0 ]; then
    echo "Generating tokens for $HOST_COUNT host(s)..."
    
    for HOST_ID in $(seq 1 $HOST_COUNT); do
      gosu clusterio npx clusteriocontroller --log-level error bootstrap generate-host-token "$HOST_ID" --config "$CONFIG_PATH" > "$TOKENS_DIR/clusterio-host-${HOST_ID}.token"
      echo "  Token generated: clusterio-host-${HOST_ID}.token"
    done
  fi
fi

# Start controller in background
gosu clusterio npx clusteriocontroller run --config "$CONFIG_PATH" &
CONTROLLER_PID=$!

# Forward signals to the controller process for graceful shutdown
trap 'kill $CONTROLLER_PID; wait $CONTROLLER_PID; exit $?' SIGTERM SIGINT

# Wait for controller to be ready
echo "Waiting for controller to start..."
until curl -sf http://localhost:${CONTROLLER_HTTP_PORT:-8080}/ > /dev/null 2>&1; do
    sleep 2
done
echo "Controller is ready"

# On first run, seed data via API (requires running controller)
if [ "$FIRST_RUN" = true ]; then
  CONTROL_CONFIG="$TOKENS_DIR/config-control.json"

  # Set default mod pack (required for instances to start)
  DEFAULT_MOD_PACK="${DEFAULT_MOD_PACK:-Base Game 2.0}"
  echo "Setting default mod pack: $DEFAULT_MOD_PACK"
  MOD_PACK_ID=$(gosu clusterio npx clusterioctl --log-level error mod-pack list \
    --config "$CONTROL_CONFIG" 2>/dev/null \
    | grep "$DEFAULT_MOD_PACK" | awk -F'|' '{print $1}' | tr -d ' ')
  if [ -n "$MOD_PACK_ID" ]; then
    gosu clusterio npx clusterioctl --log-level error controller config set \
      controller.default_mod_pack_id "$MOD_PACK_ID" \
      --config "$CONTROL_CONFIG" 2>/dev/null
    echo "  Default mod pack set (ID: $MOD_PACK_ID)"
  else
    echo "  WARNING: Mod pack '$DEFAULT_MOD_PACK' not found — set manually in Web UI"
  fi

  # Seed mods from seed-data/mods/
  /scripts/seed-mods.sh "$CONTROL_CONFIG"

  # Seed instances from seed-data/hosts/
  /scripts/seed-instances.sh "$CONTROL_CONFIG" "$HOST_COUNT"
fi

# Keep controller running
wait $CONTROLLER_PID