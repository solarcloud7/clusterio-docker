#!/bin/bash
set -e

echo "========================================"
echo "Clusterio Host Startup: ${HOST_NAME}"
echo "========================================"

# Create necessary directories as root
# Use workaround for Docker Desktop/WSL2 caching bug where mkdir fails on "ghost" directories
for dir in /clusterio/logs /clusterio/instances /clusterio/plugins; do
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || {
      # WSL2 bug workaround: if mkdir fails, try removing any ghost entry first
      rm -rf "$dir" 2>/dev/null || true
      mkdir -p "$dir"
    }
  fi
done


# Sync any plugins from /opt/plugins to the host's persistent plugin directory
PLUGINS_SRC="/opt/plugins"
PLUGINS_DST="/clusterio/plugins"

if [ -d "${PLUGINS_SRC}" ] && [ "$(ls -A ${PLUGINS_SRC} 2>/dev/null)" ]; then
  echo "Syncing plugins into host persistent volume..."
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
fi

# BUGFIX: Override clusterio core modules with our fixed version (race condition fix)
# Copy the fixed impl.lua to the npm-installed location where Clusterio loads it from
echo "Installing fixed Clusterio impl.lua (race condition fix)..."
cp -f /opt/clusterio_modules/impl.lua \
  /usr/lib/node_modules/@clusterio/host/modules/clusterio/impl.lua || {
  echo "WARNING: Could not copy fixed impl.lua - race condition fix not applied"
}



# --- Clusterio admin/ban/whitelist import logic ---
echo "Importing admin, whitelist, and ban lists"

SEED_CONFIG_DIR="/opt/seed-config"



# Final consolidated ownership
chown -R factorio:factorio /clusterio

su -s /bin/bash factorio <<'FACTORIO_USER'
cd /clusterio

# Wait for host config to exist (created by init service)
HOST_CONFIG="/clusterio/config-host.json"
max_attempts=120
attempt=0
while [ ! -f "${HOST_CONFIG}" ]; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "ERROR: Host config not found after ${max_attempts} seconds"
    echo "Expected: ${HOST_CONFIG}"
    exit 1
  fi
  echo "Waiting for host configuration... ($attempt/$max_attempts)"
  sleep 2
done

echo "Host configuration found: ${HOST_CONFIG}"
echo ""

# Set Factorio directory in host config
npx clusteriohost --log-level error config set host.factorio_directory /opt/factorio
npx clusteriohost --log-level error config set host.instances_directory /clusterio/instances

echo "Starting Clusterio Host..."
echo "Host will connect to controller and wait for instance assignment."
echo "========================================"

exec npx clusteriohost run
FACTORIO_USER