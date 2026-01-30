#!/bin/bash
# controller-entrypoint.sh
set -e

TOKENS_DIR="/clusterio/tokens"

# Fix volume permissions (running as root)
chown -R clusterio:clusterio /clusterio

# Check if first run before starting
FIRST_RUN=false
if [ ! -f "/clusterio/database/users.json" ]; then
  FIRST_RUN=true
fi

# Start controller in background as clusterio user
gosu clusterio npx clusteriocontroller run &
CONTROLLER_PID=$!

# Wait for controller to be ready
echo "Waiting for controller to start..."
until curl -sf http://localhost:${CONTROLLER_HTTP_PORT:-8080}/ > /dev/null 2>&1; do
    sleep 2
done
echo "Controller is ready"

# On first run only
if [ "$FIRST_RUN" = true ]; then
  echo "First run detected, creating admin user: $INIT_CLUSTERIO_ADMIN"
  gosu clusterio npx clusteriocontroller --log-level error bootstrap create-admin "$INIT_CLUSTERIO_ADMIN"

  # Generate host tokens if HOST_COUNT is set (default: 0 for standalone usage)
  HOST_COUNT=${HOST_COUNT:-0}
  if [ "$HOST_COUNT" -gt 0 ]; then
    echo "Generating tokens for $HOST_COUNT host(s)..."
    mkdir -p "$TOKENS_DIR"
    chown clusterio:clusterio "$TOKENS_DIR"
    
    for HOST_ID in $(seq 1 $HOST_COUNT); do
      gosu clusterio npx clusteriocontroller --log-level error bootstrap generate-host-token "$HOST_ID" > "$TOKENS_DIR/clusterio-host-${HOST_ID}.token"
      chown clusterio:clusterio "$TOKENS_DIR/clusterio-host-${HOST_ID}.token"
      echo "  Host token written to $TOKENS_DIR/clusterio-host-${HOST_ID}.token"
    done
  fi
fi

# Keep controller running
wait $CONTROLLER_PID