#!/bin/bash
# host-entrypoint.sh
set -e

DATA_DIR="/clusterio/data"
CONFIG_PATH="$DATA_DIR/config-host.json"
TOKENS_DIR="/clusterio/tokens"
EXTERNAL_PLUGINS_DIR="/clusterio/external_plugins"
SEED_MODS_DIR="/clusterio/seed-mods"
HOST_MODS_DIR="/clusterio/mods"

# Use HOST_NAME env var, fallback to hostname
HOST_NAME="${HOST_NAME:-$(hostname)}"
# Extract numeric ID from host name (e.g., clusterio-host-1 -> 1)
HOST_ID=$(echo "$HOST_NAME" | grep -oE '[0-9]+$' || echo "1")
TOKEN_FILE="$TOKENS_DIR/${HOST_NAME}.token"
MAX_WAIT_SECONDS=300
WAIT_INTERVAL=5

# Create data directory and fix permissions
mkdir -p "$DATA_DIR"
chown -R clusterio:clusterio "$DATA_DIR"

# Handle external plugins if mounted
source /scripts/install-plugins.sh
install_external_plugins "$EXTERNAL_PLUGINS_DIR"

# Pre-cache seed mods so the host doesn't need to download them from the controller.
# Runs on every startup (not just first run) since the mods dir may be ephemeral.
if [ -d "$SEED_MODS_DIR" ]; then
  shopt -s nullglob
  MOD_FILES=("$SEED_MODS_DIR"/*.zip)
  shopt -u nullglob
  if [ ${#MOD_FILES[@]} -gt 0 ]; then
    mkdir -p "$HOST_MODS_DIR"
    echo "Pre-caching ${#MOD_FILES[@]} mod(s) from seed data..."
    for mod_file in "${MOD_FILES[@]}"; do
      mod_name=$(basename "$mod_file")
      if [ ! -f "$HOST_MODS_DIR/$mod_name" ]; then
        cp "$mod_file" "$HOST_MODS_DIR/$mod_name"
        echo "  Cached: $mod_name"
      fi
    done
    chown -R clusterio:clusterio "$HOST_MODS_DIR"
  fi
fi

# Determine which Factorio installation to use.
# If the full game client was installed at build time (INSTALL_FACTORIO_CLIENT=true),
# use it instead of the headless server. The client is a superset of headless for
# server mode and additionally provides icon/graphics data for Clusterio's export-data flow.
# Set SKIP_CLIENT=true to force headless even when the client is present.
FACTORIO_CLIENT_HOME="${FACTORIO_CLIENT_HOME:-/opt/factorio-client}"
if [ -d "$FACTORIO_CLIENT_HOME" ] && [ "${SKIP_CLIENT:-false}" != "true" ]; then
    FACTORIO_DIR="$FACTORIO_CLIENT_HOME"
    echo "Factorio game client detected — using $FACTORIO_DIR (enables graphical asset export)"
else
    FACTORIO_DIR="$FACTORIO_HOME"
fi

get_token() {
    # Priority 1: Environment variable (for standalone container usage)
    if [ -n "$CLUSTERIO_HOST_TOKEN" ]; then
        echo "$CLUSTERIO_HOST_TOKEN"
        return 0
    fi
    
    # Priority 2: Token file from shared volume (docker-compose usage)
    if [ -f "$TOKEN_FILE" ]; then
        cat "$TOKEN_FILE"
        return 0
    fi
    
    return 1
}

# Check if already configured (config file exists with token)
if [ -f "$CONFIG_PATH" ]; then
    EXISTING_TOKEN=$(gosu clusterio npx clusteriohost --log-level error config get host.controller_token --config "$CONFIG_PATH" 2>/dev/null || echo "")
    if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "null" ]; then
        # Sanity check: a valid JWT has exactly 2 dots (three base64 segments).
        # A malformed token causes fatal auth failure — reconfigure if invalid.
        TOKEN_DOTS=$(echo "$EXISTING_TOKEN" | tr -cd '.' | wc -c)
        if [ "$TOKEN_DOTS" -ne 2 ]; then
            echo "Stored token is malformed (not a valid JWT) — reconfiguring host..."
            rm -f "$CONFIG_PATH"
        fi

        # Token desync detection: if the shared token volume has a different token
        # (e.g. controller volume was wiped and regenerated), reconfigure the host
        if [ -f "$CONFIG_PATH" ] && [ -f "$TOKEN_FILE" ]; then
            NEW_TOKEN=$(cat "$TOKEN_FILE")
            if [ "$EXISTING_TOKEN" != "$NEW_TOKEN" ]; then
                echo "Token mismatch detected (controller may have been re-initialized) — reconfiguring host..."
                rm -f "$CONFIG_PATH"
            fi
        fi

        # If config still exists (no desync), check factorio_directory is up to date
        if [ -f "$CONFIG_PATH" ]; then
            CURRENT_FACTORIO_DIR=$(gosu clusterio npx clusteriohost --log-level error config get host.factorio_directory --config "$CONFIG_PATH" 2>/dev/null || echo "")
            if [ -n "$CURRENT_FACTORIO_DIR" ] && [ "$CURRENT_FACTORIO_DIR" != "$FACTORIO_DIR" ]; then
                echo "Updating factorio_directory: $CURRENT_FACTORIO_DIR → $FACTORIO_DIR"
                gosu clusterio npx clusteriohost --log-level error config set host.factorio_directory "$FACTORIO_DIR" --config "$CONFIG_PATH"
            fi
            echo "Host already configured, starting..."
            exec gosu clusterio npx clusteriohost run --config "$CONFIG_PATH"
        fi
    fi
fi

# Wait for token to become available
echo "Waiting for host token..."
WAITED=0
while ! TOKEN=$(get_token); do
    if [ $WAITED -ge $MAX_WAIT_SECONDS ]; then
        echo "ERROR: Timed out waiting for host token after ${MAX_WAIT_SECONDS}s"
        echo "Either set CLUSTERIO_HOST_TOKEN environment variable or ensure shared volume is mounted"
        exit 1
    fi
    echo "Token not available yet, waiting... (${WAITED}s/${MAX_WAIT_SECONDS}s)"
    sleep $WAIT_INTERVAL
    WAITED=$((WAITED + WAIT_INTERVAL))
done

echo "Configuring host (ID: $HOST_ID, Name: $HOST_NAME)..."

# Derive game port range from HOST_ID so each host uses non-overlapping ports.
# Pattern: host N → 34N00 – 34N99 (e.g., host 1 → 34100-34199, host 2 → 34200-34299)
# Override with FACTORIO_PORT_RANGE env var if needed.
DEFAULT_PORT_START=$((34000 + HOST_ID * 100))
DEFAULT_PORT_END=$((DEFAULT_PORT_START + 99))
FACTORIO_PORT_RANGE="${FACTORIO_PORT_RANGE:-${DEFAULT_PORT_START}-${DEFAULT_PORT_END}}"

# Configure host with paths relative to data volume
gosu clusterio npx clusteriohost --log-level error config set host.id "$HOST_ID" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.name "$HOST_NAME" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.controller_url "${CONTROLLER_URL:-http://clusterio-controller:8080/}" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.controller_token "$TOKEN" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.factorio_directory "$FACTORIO_DIR" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.instances_directory "$DATA_DIR/instances" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.factorio_port_range "$FACTORIO_PORT_RANGE" --config "$CONFIG_PATH"

# Start the host
exec gosu clusterio npx clusteriohost run --config "$CONFIG_PATH"