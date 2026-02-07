#!/bin/bash
# host-entrypoint.sh
set -e

DATA_DIR="/clusterio/data"
CONFIG_PATH="$DATA_DIR/config-host.json"
TOKENS_DIR="/clusterio/tokens"
EXTERNAL_PLUGINS_DIR="/clusterio/external_plugins"

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
if [ -d "$EXTERNAL_PLUGINS_DIR" ] && [ "$(ls -A $EXTERNAL_PLUGINS_DIR 2>/dev/null)" ]; then
  echo "External plugins detected, installing..."
  chown -R clusterio:clusterio "$EXTERNAL_PLUGINS_DIR"
  for plugin in "$EXTERNAL_PLUGINS_DIR"/*/; do
    if [ -f "${plugin}package.json" ]; then
      plugin_name=$(basename "$plugin")
      echo "  Installing plugin: $plugin_name"
      (cd "$plugin" && gosu clusterio npm install --omit=dev 2>/dev/null || true)
    fi
  done
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
        echo "Host already configured, starting..."
        exec gosu clusterio npx clusteriohost run --config "$CONFIG_PATH"
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

# Configure host with paths relative to data volume
gosu clusterio npx clusteriohost --log-level error config set host.id "$HOST_ID" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.name "$HOST_NAME" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.controller_url "${CONTROLLER_URL:-http://clusterio-controller:8080/}" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.controller_token "$TOKEN" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.factorio_directory /opt/factorio --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.instances_directory "$DATA_DIR/instances" --config "$CONFIG_PATH"

# Start the host
exec gosu clusterio npx clusteriohost run --config "$CONFIG_PATH"