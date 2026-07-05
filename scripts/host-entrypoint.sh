#!/bin/bash
# host-entrypoint.sh
set -eo pipefail

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
  # Pass the credentialed URL via curl's config on stdin (-K -) so the Factorio
  # token does not appear in the process list / proc args during the download.
  curl -fL --retry 8 -o "$archive" -K - <<EOF
url = "https://factorio.com/get-download/${FACTORIO_CLIENT_TAG}/${FACTORIO_CLIENT_BUILD}/linux64?username=${FACTORIO_USERNAME}&token=${FACTORIO_TOKEN}"
EOF
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
    # Headless host: FACTORIO_HOME is a multi-version parent dir (baked install lives in
    # a subdir). Pointing factorio_directory here — rather than at a direct install — lets
    # Clusterio auto-download/update the target headless version at runtime on Linux.
    FACTORIO_DIR="$FACTORIO_HOME"
    echo "No game client present — using headless directory $FACTORIO_DIR (auto-update enabled)"
fi

# Config-contradiction guard: EXPORT_HOST designates a host to run export-data,
# which needs the full game client — SKIP_CLIENT=true on that same host
# guarantees blank web-UI icons via a distant, confusing failure. Warn at the
# source instead (docs/asset-export.md).
if [ "${EXPORT_HOST:-0}" = "$HOST_ID" ] && [ "${SKIP_CLIENT:-false}" = "true" ]; then
  echo "WARNING: EXPORT_HOST=$EXPORT_HOST designates THIS host ($HOST_NAME) for export-data, but SKIP_CLIENT=true forces headless — export will fail and web-UI icons will be blank (docs/asset-export.md)" >&2
fi

# Diagnostic: report which Factorio version(s) are present in the resolved directory. Clusterio
# resolves the Factorio binary by version, so a mismatch between what is installed here and an
# instance's pinned `factorio.version` is a common — and otherwise hard to diagnose — cause of
# an instance failing to start: the host throws "Unable to find Factorio version X" (or
# downloads X) before the server launches, and that lands in this host log, not the instance's
# factorio-current.log. Logging the installed version here makes the mismatch visible up front.
report_factorio_versions() {
    local dir="$1" changelog version found=""
    for changelog in "$dir/data/changelog.txt" "$dir"/*/data/changelog.txt; do
        [ -f "$changelog" ] || continue
        # Best-effort: a changelog with no `Version:` line (or a partially-written file) makes
        # grep -m1 exit 1, which pipefail propagates and `set -e` would turn into an entrypoint
        # abort. This is diagnostic-only, so never let it fail startup — fall back to empty and let
        # the `[ -n ]` check below skip it.
        version=$(grep -m1 -iE '^Version:' "$changelog" 2>/dev/null | sed -E 's/^[Vv]ersion:[[:space:]]*//') || true
        [ -n "$version" ] && found="${found:+$found, }$version"
    done
    echo "Factorio install(s) under $dir: ${found:-none (will be downloaded at runtime)}"
}
report_factorio_versions "$FACTORIO_DIR"

# ----------------------------------------------------------------------------
# Boot-race guard.
# An instance that auto-starts before this host completes its controller
# handshake silently skips instance plugins — no error, IPC just goes nowhere
# (README: "Operational note: the instance/plugin boot race"). This guard
# mechanizes the manual stop/start protocol: once the controller reports this
# host connected, it restarts any of this host's instances whose startedAtMs
# PREDATES the handshake. Instances started after (e.g. by first-run seeding)
# are untouched, so healthy boots are a no-op — the bounce is surgical.
# Requires the shared tokens volume (config-control.json); standalone hosts
# without it skip quietly and the manual protocol still applies.
# The true fix (loud failure in Clusterio core) is tracked upstream.
# ----------------------------------------------------------------------------
CONTROL_CONFIG="${CONTROL_CONFIG:-$TOKENS_DIR/config-control.json}"
# The shared control config is CONTROLLER-LOCAL: create-ctl-config bakes
# controller_url=http://localhost:8080/, which from a host container points at
# the host itself — and clusterioctl HANGS on it rather than refusing (#24's
# second root cause). The guard derives a host-reachable copy using the same
# CONTROLLER_URL this entrypoint configures clusteriohost with.
GUARD_CTL_CONFIG="$DATA_DIR/.guard-control.json"
GUARD_CONTROLLER_URL="${CONTROLLER_URL:-http://clusterio-controller:${CONTROLLER_HTTP_PORT:-8080}/}"
GUARD_LOG="$DATA_DIR/boot-race-guard.log"

ctl_ro() {
    # Hard-bounded: clusterioctl has no client-side timeout and HANGS indefinitely
    # against an unreachable or mid-boot controller (#24 — the guard's first
    # host-list call froze forever, so neither progress nor the deadline message
    # ever appeared). timeout's exit 124 just makes the poll loops iterate.
    timeout -k 5 25 gosu clusterio npx clusterioctl --log-level error "$@" --config "$GUARD_CTL_CONFIG" 2>/dev/null
}

# Guard messages go to BOTH stdout and a file: if stdout capture ever fails,
# the file still proves whether (and how far) the guard ran (#24 discriminator).
guard_log() {
    echo "boot-race guard: $*"
    echo "$(date -u +%FT%TZ) $*" >> "$GUARD_LOG" 2>/dev/null || true
}

boot_race_guard() {
    # Wall-clock deadline (SECONDS is bash's elapsed timer): each ctl_ro poll can
    # itself burn up to ~25s in timeout, so counting sleeps alone would stretch
    # the nominal deadline to many minutes of real time.
    local deadline=$((SECONDS + 240)) T inst w
    guard_log "started (pid $$, host $HOST_NAME/$HOST_ID)"
    while [ ! -f "$CONTROL_CONFIG" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            guard_log "no control config appeared (standalone host?) — skipping"
            return 0
        fi
        sleep 5
    done
    if ! node -e '
        const fs = require("fs");
        const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        c["control.controller_url"] = process.argv[3];
        fs.writeFileSync(process.argv[2], JSON.stringify(c, null, "\t"));
    ' "$CONTROL_CONFIG" "$GUARD_CTL_CONFIG" "$GUARD_CONTROLLER_URL" 2>/dev/null; then
        guard_log "could not derive a host-reachable control config — skipping"
        return 0
    fi
    guard_log "control config present (rewritten controller_url -> $GUARD_CONTROLLER_URL) — waiting for controller to report this host connected"
    until ctl_ro host list | awk -F'|' -v n="$HOST_NAME" \
        'function t(s){gsub(/^ +| +$/,"",s);return s} NR>2 && t($2)==n && t($4)=="true"{ok=1} END{exit !ok}'; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            guard_log "host never reported connected within the deadline — skipping"
            return 0
        fi
        sleep 5
    done
    T=$(node -e 'console.log(Date.now())')
    guard_log "handshake confirmed at $T — checking for instances started before it"
    ctl_ro instance list | awk -F'|' -v hid="$HOST_ID" -v T="$T" \
        'function t(s){gsub(/^ +| +$/,"",s);return s} NR>2 && t($3)==hid && (t($5)=="running"||t($5)=="starting") && t($7)+0>0 && t($7)+0<T {print t($1)}' \
    | while IFS= read -r inst; do
        guard_log "'$inst' started before the handshake — restarting it so plugins register"
        ctl_ro instance stop "$inst" || true
        w=$((SECONDS + 90))
        until ctl_ro instance list | awk -F'|' -v i="$inst" \
            'function t(s){gsub(/^ +| +$/,"",s);return s} NR>2 && t($1)==i && t($5)=="stopped"{ok=1} END{exit !ok}'; do
            if [ "$SECONDS" -ge "$w" ]; then
                guard_log "'$inst' did not stop within the wait budget — leaving it as-is"
                break
            fi
            sleep 3
        done
        ctl_ro instance start "$inst" || true
        guard_log "'$inst' restarted after handshake"
    done
    guard_log "complete"
}

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
            boot_race_guard &
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
gosu clusterio npx clusteriohost --log-level error config set host.controller_url "${CONTROLLER_URL:-http://clusterio-controller:${CONTROLLER_HTTP_PORT:-8080}/}" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.controller_token "$TOKEN" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.factorio_directory "$FACTORIO_DIR" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.instances_directory "$DATA_DIR/instances" --config "$CONFIG_PATH"
gosu clusterio npx clusteriohost --log-level error config set host.factorio_port_range "$FACTORIO_PORT_RANGE" --config "$CONFIG_PATH"

# Start the host
boot_race_guard &
exec gosu clusterio npx clusteriohost run --config "$CONFIG_PATH"