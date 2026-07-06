#!/bin/bash
# controller-entrypoint.sh
set -eo pipefail

DATA_DIR="/clusterio/data"
CONFIG_PATH="$DATA_DIR/config-controller.json"
TOKENS_DIR="/clusterio/tokens"
EXTERNAL_PLUGINS_DIR="/clusterio/external_plugins"
SEED_DATA_DIR="/clusterio/seed-data"

# Create data directory and fix permissions
mkdir -p "$DATA_DIR" "$TOKENS_DIR"
chown -R clusterio:clusterio "$DATA_DIR" "$TOKENS_DIR"

# Clean up stale lock files from an unclean shutdown (e.g. docker restart).
# Assumes a single controller per data volume (the supported topology); only
# removes (and logs) when a lock is actually present. Clusterio's own lock files
# (#815) are what guard against two controllers concurrently sharing a volume.
if compgen -G "$DATA_DIR/*.lock" > /dev/null 2>&1; then
  echo "Removing stale controller lock file(s) from a previous run"
  rm -f "$DATA_DIR"/*.lock
fi

# Honest readiness: the healthcheck requires this marker, written only when the
# entrypoint reaches steady state (post-seeding) — clear any stale copy first.
rm -f "$DATA_DIR/.seed-healthy"

# Mirror Clusterio's on-disk cluster log to stdout (CLUSTERIO_LOG_TO_STDOUT).
source /scripts/stream-logs.sh
start_log_streamer /clusterio/logs/cluster cluster

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
  if [ -n "$FACTORIO_USERNAME" ]; then
    gosu clusterio npx clusteriocontroller --log-level error config set controller.factorio_username "$FACTORIO_USERNAME" --config "$CONFIG_PATH"
  fi
  if [ -n "$FACTORIO_TOKEN" ]; then
    gosu clusterio npx clusteriocontroller --log-level error config set controller.factorio_token "$FACTORIO_TOKEN" --config "$CONFIG_PATH"
  fi

  # --- Bootstrap (must run BEFORE controller starts) ---
  # These commands modify database files on disk. The controller loads them
  # into memory at startup, so they must be written before `controller run`.

  if [ -z "$INIT_CLUSTERIO_ADMIN" ]; then
    echo "ERROR: INIT_CLUSTERIO_ADMIN is not set. Cannot create admin user."
    echo "       Set it in .env or as an environment variable."
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
  # create-ctl-config writes config-control.json to the working directory.
  # Fail with a clear message rather than a cryptic `mv` error if it's absent.
  if [ -f /clusterio/config-control.json ]; then
    mv /clusterio/config-control.json "$CONTROL_CONFIG"
  else
    echo "ERROR: create-ctl-config did not produce /clusterio/config-control.json — cannot provision API token" >&2
    exit 1
  fi
  
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

# Static-cache patch (absorbed consumer fix): the controller serves /static with
# immutable 1y headers, pinning stale web-UI chunks on returning browsers after
# upgrades. Flip to revalidation unless the consumer explicitly opts out.
if [ "${CONTROLLER_STATIC_CACHE_MODE:-revalidate}" != "immutable" ]; then
  node /scripts/patches/disable-immutable-cache.js
fi

# Start controller in background
gosu clusterio npx clusteriocontroller run --config "$CONFIG_PATH" &
CONTROLLER_PID=$!

# Forward signals to the controller process and optional bridge for graceful shutdown
trap 'kill $CONTROLLER_PID ${BRIDGE_PID:-} 2>/dev/null; wait $CONTROLLER_PID; exit $?' SIGTERM SIGINT

# Wait for controller to be ready
echo "Waiting for controller to start..."
until curl -sf http://localhost:${CONTROLLER_HTTP_PORT:-8080}/ > /dev/null 2>&1; do
    sleep 2
done
echo "Controller is ready"

# On first run, seed data via API (requires running controller)
# Also re-attempt if a previous first run was interrupted (marker not written)
SEED_MARKER="$DATA_DIR/.seed-complete"
CONTROL_CONFIG="$TOKENS_DIR/config-control.json"

# Resolve default mod pack ID (used by both first-run seeding and ongoing mod uploads)
DEFAULT_MOD_PACK="${DEFAULT_MOD_PACK:-Base Game 2.1}"
DEFAULT_FACTORIO_VERSION="${DEFAULT_FACTORIO_VERSION:-2.1}"
MOD_PACK_ID=$(gosu clusterio npx clusterioctl --log-level error mod-pack list \
  --config "$CONTROL_CONFIG" 2>/dev/null \
  | grep "$DEFAULT_MOD_PACK" | awk -F'|' '{print $1}' | tr -d ' ' || true)

# If the requested mod pack doesn't exist, create it — but only during the
# seeding window (first run, or seeding not yet complete). This prevents a
# transient `mod-pack list` failure on a later boot (which leaves MOD_PACK_ID
# empty) from creating a duplicate pack.
if [ -z "$MOD_PACK_ID" ] && { [ "$FIRST_RUN" = true ] || [ ! -f "$SEED_MARKER" ]; }; then
  echo "Mod pack '$DEFAULT_MOD_PACK' not found — creating it (Factorio $DEFAULT_FACTORIO_VERSION)..."
  CREATE_OUTPUT=$(gosu clusterio npx clusterioctl --log-level error mod-pack create \
    "$DEFAULT_MOD_PACK" "$DEFAULT_FACTORIO_VERSION" \
    --config "$CONTROL_CONFIG" 2>/dev/null)
  echo "  $CREATE_OUTPUT"
  # Parse ID from output: "Created mod pack <name> (<id>)"
  MOD_PACK_ID=$(echo "$CREATE_OUTPUT" | grep -oE '\([0-9]+\)' | tr -d '()' || true)
  if [ -z "$MOD_PACK_ID" ]; then
    echo "  WARNING: Failed to create mod pack '$DEFAULT_MOD_PACK'"
  fi

  # Enable DLC mods if the pack name contains "Space Age" (Clusterio creates
  # builtin DLC mods as disabled by default — this enables them explicitly).
  # recycler is included because space-age + quality hard-depend on it in
  # Factorio 2.1.x; without it the save fails to load and every consumer ends
  # up patching this list downstream.
  if [ -n "$MOD_PACK_ID" ] && echo "$DEFAULT_MOD_PACK" | grep -qi "space.age"; then
    echo "  Enabling DLC mods (space-age, elevated-rails, quality, recycler)..."
    # Non-fatal but loud: under `set -e` a failing enable (e.g. an older core
    # without the `recycler` builtin) would otherwise crash-loop the whole
    # controller. A pack missing a DLC mod is recoverable; a dead controller
    # is not. (Found the hard way: an alpha.25-era custom build did exactly
    # this and the container restart-looped until compose gave up.)
    gosu clusterio npx clusterioctl --log-level error mod-pack edit "$MOD_PACK_ID" \
      --enable-mods space-age elevated-rails quality recycler \
      --config "$CONTROL_CONFIG" 2>/dev/null \
      || echo "  WARNING: enabling DLC mods failed (core too old for one of them?) — pack '$DEFAULT_MOD_PACK' may need manual mod-pack edit" >&2
  fi
fi

if [ "$FIRST_RUN" = true ] || [ ! -f "$SEED_MARKER" ]; then
  # Set default mod pack (required for instances to start)
  echo "Setting default mod pack: $DEFAULT_MOD_PACK"
  if [ -n "$MOD_PACK_ID" ]; then
    gosu clusterio npx clusterioctl --log-level error controller config set \
      controller.default_mod_pack_id "$MOD_PACK_ID" \
      --config "$CONTROL_CONFIG" 2>/dev/null
    echo "  Default mod pack set (ID: $MOD_PACK_ID)"
  else
    echo "  WARNING: Mod pack '$DEFAULT_MOD_PACK' not found — set manually in Web UI"
  fi

  # Seed mods before instances (instances may need them to start)
  /scripts/seed-mods.sh "$CONTROL_CONFIG" "$MOD_PACK_ID"

  # Seed instances from seed-data/hosts/
  /scripts/seed-instances.sh "$CONTROL_CONFIG" "$HOST_COUNT"

  # Mark seeding as complete so restarts don't re-seed
  touch "$SEED_MARKER"
  chown clusterio:clusterio "$SEED_MARKER"
  echo "Seeding complete."
else
  # Not first run — upload any new mods added since last run (existing mods are skipped)
  /scripts/seed-mods.sh "$CONTROL_CONFIG" "$MOD_PACK_ID"
fi

# Optional Discord bridge: start only after the controller has reached the same
# steady-state point used for honest readiness. The bridge is private to a
# dedicated Docker network; do not publish BRIDGE_PORT to the host.
if [ -n "${BRIDGE_PORT:-}" ]; then
  if [ -z "${BRIDGE_TOKEN:-}" ]; then
    echo "ERROR: BRIDGE_TOKEN is required when BRIDGE_PORT is set." >&2
    kill "$CONTROLLER_PID" 2>/dev/null || true
    wait "$CONTROLLER_PID" 2>/dev/null || true
    exit 1
  fi
  if [ -z "${BRIDGE_BIND_HOST:-}" ]; then
    echo "ERROR: BRIDGE_BIND_HOST is required when BRIDGE_PORT is set." >&2
    kill "$CONTROLLER_PID" 2>/dev/null || true
    wait "$CONTROLLER_PID" 2>/dev/null || true
    exit 1
  fi
  echo "Starting Clusterio Discord bridge on ${BRIDGE_BIND_HOST}:${BRIDGE_PORT}"
  BRIDGE_CONFIG="$CONTROL_CONFIG" BRIDGE_PORT="$BRIDGE_PORT" BRIDGE_TOKEN="$BRIDGE_TOKEN" \
    BRIDGE_BIND_HOST="$BRIDGE_BIND_HOST" BRIDGE_ALLOWED_CIDRS="${BRIDGE_ALLOWED_CIDRS:-}" \
    BRIDGE_ALLOW_RAW="${BRIDGE_ALLOW_RAW:-false}" \
    gosu clusterio node /clusterio/bridge.mjs &
  BRIDGE_PID=$!
  sleep 1
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "ERROR: Clusterio Discord bridge exited during startup." >&2
    kill "$CONTROLLER_PID" 2>/dev/null || true
    wait "$CONTROLLER_PID" 2>/dev/null || true
    exit 1
  fi
fi

# Honest readiness: everything above (config, bootstrap, seeding, optional bridge launch)
# completed — only now does the healthcheck's marker requirement pass.
touch "$DATA_DIR/.seed-healthy"
echo "Entrypoint steady state reached — controller healthcheck can now pass"

# Keep controller running
wait $CONTROLLER_PID