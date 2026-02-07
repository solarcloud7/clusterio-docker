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
    fi
  done
}
