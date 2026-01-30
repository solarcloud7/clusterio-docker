#!/bin/bash
# host-entrypoint.sh
set -e

TOKENS_DIR="/clusterio/tokens"
# Use HOST_NAME env var, fallback to hostname, then default
HOST_NAME="${HOST_NAME:-$(hostname)}"
# Extract numeric ID from host name (e.g., clusterio-host-1 -> 1)
HOST_ID=$(echo "$HOST_NAME" | grep -oE '[0-9]+$' || echo "1")
TOKEN_FILE="$TOKENS_DIR/${HOST_NAME}.token"
MAX_WAIT_SECONDS=300
WAIT_INTERVAL=5

# Fix volume permissions for writable directories only
chown -R clusterio:clusterio /clusterio/instances /clusterio/logs 2>/dev/null || true

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

# Check if token is already configured
EXISTING_TOKEN=$(gosu clusterio npx clusteriohost --log-level error config get host.controller_token 2>/dev/null || echo "")
if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "null" ]; then
    echo "Host token already configured, starting host..."
    exec gosu clusterio npx clusteriohost run
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

echo "Host token obtained, configuring host (ID: $HOST_ID)..."
gosu clusterio npx clusteriohost --log-level error config set host.id "$HOST_ID"
gosu clusterio npx clusteriohost --log-level error config set host.name "$HOST_NAME"
gosu clusterio npx clusteriohost --log-level error config set host.controller_token "$TOKEN"

# Start the host
exec gosu clusterio npx clusteriohost run