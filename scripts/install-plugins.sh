#!/bin/bash
# install-plugins.sh
# Shared helper: installs external plugins if mounted.
# Usage: source /path/to/install-plugins.sh
#        install_external_plugins "/clusterio/external_plugins"

install_external_plugins() {
  local plugins_dir="$1"

  if [ ! -d "$plugins_dir" ] || [ -z "$(ls -A "$plugins_dir" 2>/dev/null)" ]; then
    return 0
  fi

  echo "External plugins detected, installing..."
  chown -R clusterio:clusterio "$plugins_dir"

  for plugin in "$plugins_dir"/*/; do
    if [ -f "${plugin}package.json" ]; then
      local plugin_name
      plugin_name=$(basename "$plugin")
      echo "  Installing plugin: $plugin_name"
      (cd "$plugin" && gosu clusterio npm install --omit=dev 2>/dev/null || true)

      # Remove any @clusterio packages that npm may have installed locally.
      # Plugins declare @clusterio/* as peerDependencies, but npm v7+ can
      # lock and install them into the plugin's own node_modules. This creates
      # duplicate singletons (e.g. two copies of @clusterio/lib) — the plugin
      # registers permissions/events in its copy while the controller reads
      # from the monorepo copy, causing "permission not found" errors.
      # Removing them forces Node.js to resolve upward to the shared copies.
      if [ -d "${plugin}node_modules/@clusterio" ]; then
        echo "    Removing local @clusterio packages (using shared monorepo copies)"
        rm -rf "${plugin}node_modules/@clusterio"
      fi
    fi
  done
}
