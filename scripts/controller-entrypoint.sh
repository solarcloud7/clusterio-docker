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

# Check if first run (no config file yet)
FIRST_RUN=false
if [ ! -f "$CONFIG_PATH" ]; then
  FIRST_RUN=true
  echo "First run detected, configuring controller..."
  
  # Configure paths relative to data volume
  gosu clusterio npx clusteriocontroller --log-level error config set controller.database_directory "$DATA_DIR/database" --config "$CONFIG_PATH"
  gosu clusterio npx clusteriocontroller --log-level error config set controller.http_port "${CONTROLLER_HTTP_PORT:-8080}" --config "$CONFIG_PATH"
  gosu clusterio npx clusteriocontroller --log-level error config set controller.external_address "${CONTROLLER_PUBLIC_ADDRESS:-http://localhost:8080/}" --config "$CONFIG_PATH"
fi

# Start controller in background
gosu clusterio npx clusteriocontroller run --config "$CONFIG_PATH" &
CONTROLLER_PID=$!

# Wait for controller to be ready
echo "Waiting for controller to start..."
until curl -sf http://localhost:${CONTROLLER_HTTP_PORT:-8080}/ > /dev/null 2>&1; do
    sleep 2
done
echo "Controller is ready"

# On first run, create admin and generate host tokens
if [ "$FIRST_RUN" = true ]; then
  echo "Creating admin user: $INIT_CLUSTERIO_ADMIN"
  gosu clusterio npx clusteriocontroller --log-level error bootstrap create-admin "$INIT_CLUSTERIO_ADMIN" --config "$CONFIG_PATH"

  # Generate host tokens if HOST_COUNT is set (default: 0 for standalone usage)
  HOST_COUNT=${HOST_COUNT:-0}
  if [ "$HOST_COUNT" -gt 0 ]; then
    echo "Generating tokens for $HOST_COUNT host(s)..."
    
    for HOST_ID in $(seq 1 $HOST_COUNT); do
      gosu clusterio npx clusteriocontroller --log-level error bootstrap generate-host-token "$HOST_ID" --config "$CONFIG_PATH" > "$TOKENS_DIR/clusterio-host-${HOST_ID}.token"
      echo "  Token generated: clusterio-host-${HOST_ID}.token"
    done
  fi

  # Seed instances from seed-data/hosts/<hostname>/instances/ if mounted
  if [ -d "$SEED_DATA_DIR/hosts" ]; then
    echo "Processing seed data..."
    for host_dir in "$SEED_DATA_DIR/hosts"/*/; do
      if [ -d "$host_dir" ]; then
        host_name=$(basename "$host_dir")
        # Extract host ID from folder name (e.g., clusterio-host-1 -> 1)
        host_id=$(echo "$host_name" | grep -oE '[0-9]+$' || echo "")
        
        if [ -z "$host_id" ]; then
          echo "  Warning: Could not extract host ID from '$host_name', skipping"
          continue
        fi
        
        echo "  Processing host: $host_name (ID: $host_id)"
        
        # Process each instance directory under this host
        for instance_dir in "$host_dir"*/; do
          if [ -d "$instance_dir" ]; then
            instance_name=$(basename "$instance_dir")
            echo "    Creating instance: $instance_name"
            
            # Create the instance
            gosu clusterio npx clusterioctl --log-level error instance create "$instance_name" --config "$CONFIG_PATH" 2>/dev/null || true
            
            # Assign to this host
            echo "      Assigning to host $host_id"
            gosu clusterio npx clusterioctl --log-level error instance assign "$instance_name" "$host_id" --config "$CONFIG_PATH" 2>/dev/null || true
            
            # Upload any save files (.zip)
            for save_file in "${instance_dir}"*.zip; do
              if [ -f "$save_file" ]; then
                save_name=$(basename "$save_file")
                echo "      Uploading save: $save_name"
                gosu clusterio npx clusterioctl --log-level error instance save upload "$instance_name" "$save_file" --config "$CONFIG_PATH" 2>/dev/null || true
              fi
            done
          fi
        done
      fi
    done
  fi
fi

# Keep controller running
wait $CONTROLLER_PID