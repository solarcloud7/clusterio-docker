#!/bin/bash
set -e

# Create necessary directories as root
# Use workaround for Docker Desktop/WSL2 caching bug where mkdir fails on "ghost" directories
for dir in /clusterio/logs /clusterio/plugins /clusterio/database; do
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || {
      # WSL2 bug workaround: if mkdir fails, try removing any ghost entry first
      rm -rf "$dir" 2>/dev/null || true
      mkdir -p "$dir"
    }
  fi
done
chown -R factorio:factorio /clusterio

# Use CONTROLLER_HTTP_PORT from docker-compose, default to 8443
HTTP_PORT=${CONTROLLER_HTTP_PORT:-8443}

# Sync any plugins from /opt/plugins to the controller's persistent plugin directory
# Plugins are mounted at runtime, not baked into the image
PLUGINS_SRC="/opt/plugins"
PLUGINS_DST="/clusterio/plugins"

if [ -d "${PLUGINS_SRC}" ] && [ "$(ls -A ${PLUGINS_SRC} 2>/dev/null)" ]; then
  echo "Syncing plugins into controller persistent volume..."
  mkdir -p "${PLUGINS_DST}"

  for plugin_dir in "${PLUGINS_SRC}"/*; do
    if [ -d "$plugin_dir" ]; then
      plugin_name=$(basename "$plugin_dir")
      echo "  - Syncing plugin: ${plugin_name}"
      rm -rf "${PLUGINS_DST}/${plugin_name}"
      cp -R "$plugin_dir" "${PLUGINS_DST}/${plugin_name}"

      # Clusterio save patching discovers Lua modules under `<plugin>/modules/<moduleName>/`.
      # If plugin has a `module/` directory, create a compatible view.
      if [ -d "${PLUGINS_DST}/${plugin_name}/module" ] && [ ! -e "${PLUGINS_DST}/${plugin_name}/modules/${plugin_name}" ]; then
        mkdir -p "${PLUGINS_DST}/${plugin_name}/modules"
        ln -s "${PLUGINS_DST}/${plugin_name}/module" "${PLUGINS_DST}/${plugin_name}/modules/${plugin_name}"
      fi
    fi
  done
else
  echo "No plugins found in ${PLUGINS_SRC}"
fi

# Create plugin-list.json to register the globally-installed official plugins
# These were installed via npm in the base image
# Use full paths because Clusterio reads package.json directly (not via require.resolve)
PLUGIN_LIST="/clusterio/plugin-list.json"
if [ ! -f "$PLUGIN_LIST" ]; then
  echo "Creating plugin-list.json with official plugins..."
  cat > "$PLUGIN_LIST" << 'EOF'
[
	["global_chat", "/usr/lib/node_modules/@clusterio/plugin-global_chat"],
	["inventory_sync", "/usr/lib/node_modules/@clusterio/plugin-inventory_sync"],
	["player_auth", "/usr/lib/node_modules/@clusterio/plugin-player_auth"],
	["research_sync", "/usr/lib/node_modules/@clusterio/plugin-research_sync"],
	["statistics_exporter", "/usr/lib/node_modules/@clusterio/plugin-statistics_exporter"],
	["subspace_storage", "/usr/lib/node_modules/@clusterio/plugin-subspace_storage"]
]
EOF
  chown factorio:factorio "$PLUGIN_LIST"
fi

# Initialize controller config if it does not exist
if [ ! -f "/clusterio/config-controller.json" ]; then
  echo "Creating controller configuration..."
  npx clusteriocontroller --log-level error config set controller.name "Clusterio Controller"
else
  echo "Using existing controller configuration."
fi

# Always ensure critical settings are configured (port may be missing from old configs)
echo "Configuring controller settings..."
npx clusteriocontroller --log-level error config set controller.bind_address "0.0.0.0"
npx clusteriocontroller --log-level error config set controller.http_port $HTTP_PORT

# Enable plugin installation (must be set locally before controller starts)
echo "Enabling plugin installation..."
npx clusteriocontroller --log-level error config set controller.allow_plugin_install true
npx clusteriocontroller --log-level error config set controller.allow_plugin_updates true

# Set Factorio credentials if provided (for mod portal downloads)
if [ -n "$FACTORIO_USERNAME" ]; then
  echo "Setting Factorio username..."
  npx clusteriocontroller --log-level error config set controller.factorio_username "$FACTORIO_USERNAME"
fi
if [ -n "$FACTORIO_TOKEN" ]; then
  echo "Setting Factorio token..."
  npx clusteriocontroller --log-level error config set controller.factorio_token "$FACTORIO_TOKEN"
fi

# Create admin user BEFORE starting controller (if not exists)
# This ensures the user is loaded into memory when controller starts
if [ ! -f "/clusterio/database/users.json" ]; then
  echo "Creating admin user..."
  npx clusteriocontroller --log-level error bootstrap create-admin admin
  echo "Admin user created successfully"
else
  echo "User database exists, skipping admin user creation"
fi

echo ""
echo "Starting Clusterio Controller..."
echo "HTTP API: http://0.0.0.0:$HTTP_PORT"
echo "WebSocket API: ws://0.0.0.0:$HTTP_PORT/api/socket (same port as HTTP)"
echo "=========================================="
exec npx clusteriocontroller run