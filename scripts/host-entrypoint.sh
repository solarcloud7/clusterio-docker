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

# Runtime Factorio client download.
# If FACTORIO_USERNAME + FACTORIO_TOKEN are set and the client is not already installed,
# download it now. The client is stored in a persistent volume so it survives `down -v`.
FACTORIO_CLIENT_HOME="${FACTORIO_CLIENT_HOME:-/opt/factorio-client}"
FACTORIO_CLIENT_VOLUME_DIR="${FACTORIO_CLIENT_VOLUME_DIR:-/opt/factorio-client}"

# Check for actual binary presence (directory may exist as an empty mount point)
client_in_image() { [ -x "$FACTORIO_CLIENT_HOME/bin/x64/factorio" ]; }
client_in_volume() { [ -x "$FACTORIO_CLIENT_VOLUME_DIR/bin/x64/factorio" ]; }

if ! client_in_image && ! client_in_volume \
   && [ -n "$FACTORIO_USERNAME" ] && [ -n "$FACTORIO_TOKEN" ] \
   && [ "${SKIP_CLIENT:-false}" != "true" ]; then
  FACTORIO_CLIENT_BUILD="${FACTORIO_CLIENT_BUILD:-expansion}"
  FACTORIO_CLIENT_TAG="${FACTORIO_CLIENT_TAG:-stable}"
  echo "Downloading Factorio game client (build=${FACTORIO_CLIENT_BUILD}, tag=${FACTORIO_CLIENT_TAG})..."
  archive="/tmp/factorio-client.tar.xz"
  curl -fL --retry 8 \
    "https://factorio.com/get-download/${FACTORIO_CLIENT_TAG}/${FACTORIO_CLIENT_BUILD}/linux64?username=${FACTORIO_USERNAME}&token=${FACTORIO_TOKEN}" \
    -o "$archive"
  mkdir -p "$FACTORIO_CLIENT_VOLUME_DIR"
  tar -xJf "$archive" -C "$FACTORIO_CLIENT_VOLUME_DIR" --strip-components=1
  rm "$archive"
  chown -R clusterio:clusterio "$FACTORIO_CLIENT_VOLUME_DIR"
  echo "Factorio game client installed to $FACTORIO_CLIENT_VOLUME_DIR"
fi

# Use volume-installed client if present (preferred), then image-baked client, then headless.
if client_in_volume && [ "${SKIP_CLIENT:-false}" != "true" ]; then
    FACTORIO_DIR="$FACTORIO_CLIENT_VOLUME_DIR"
    echo "Factorio game client (volume) detected — using $FACTORIO_DIR"
elif client_in_image && [ "${SKIP_CLIENT:-false}" != "true" ]; then
    FACTORIO_DIR="$FACTORIO_CLIENT_HOME"
    echo "Factorio game client (image) detected — using $FACTORIO_DIR"
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