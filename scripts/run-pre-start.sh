#!/bin/bash
# Called after bootstrap/configuration, before either server starts, on every boot.
set -euo pipefail
role="$1"
config="$2"
case "$role" in controller|host) ;; *) echo "Invalid startup role" >&2; exit 1;; esac
[ -f "$config" ] || { echo "Missing configuration before startup hooks" >&2; exit 1; }
export LC_ALL=C
for hook in /etc/clusterio/pre-start.d/*.sh; do
  [ -e "$hook" ] || continue
  echo "Running pre-start hook: $(basename "$hook")"
  gosu clusterio env CLUSTERIO_ROLE="$role" CLUSTERIO_CONFIG_PATH="$config" bash "$hook"
done
