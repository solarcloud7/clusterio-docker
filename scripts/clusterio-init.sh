#!/bin/bash
# Clusterio Cluster Initialization Script
# This script sets up a complete Clusterio cluster with:
# - 1 Controller (already running)
# - 2 Hosts (clusterio-host-1, clusterio-host-2)
# - 2 Instances (one per host)
#
# This script is run by the clusterio-init service container after the controller is healthy.

set -e

CONTROLLER_HTTP_PORT="${CONTROLLER_HTTP_PORT:-8080}"
CONTROLLER_URL="http://clusterio-controller:${CONTROLLER_HTTP_PORT}/"
CLUSTERIO_DIR="/clusterio"
CONFIG_CONTROL="${CLUSTERIO_DIR}/config-control.json"
CONTROLLER_MODS_DIR="${CLUSTERIO_DIR}/mods"
HOSTS_DIR="/clusterio-hosts"
MOD_PACK_NAME="${MOD_PACK_NAME:-my-server-pack}"
MOD_PACK_FACTORIO_VERSION="${MOD_PACK_FACTORIO_VERSION:-2.0}"
SEED_MODS_DIR="/opt/seed-mods"
SEED_SAVES_DIR="/opt/seed-saves"
PLUGINS_DIR="/opt/plugins"

QUIET_LOG="/clusterio/logs/init-commands.log"
QUIET_LOG_DIR="$(dirname "$QUIET_LOG")"
mkdir -p "$QUIET_LOG_DIR"
: > "$QUIET_LOG"

run_quiet() {
    local label="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "[OK] $label"
        return 0
    else
        echo "[FAIL] $label"
        {
            echo "---- $label ----"
            echo "$output"
            echo "-----------------"
        } >> "$QUIET_LOG"
        echo "    See $QUIET_LOG for command output."
        return 1
    fi
}

upload_mod_only() {
    local mod_zip="$1"
    local attempt=1
    local max_attempts=3

    if [ ! -f "$mod_zip" ]; then
        return 1
    fi

    local filename
    filename=$(basename "$mod_zip")
    local target_path="${CONTROLLER_MODS_DIR}/${filename}"

    while [ $attempt -le $max_attempts ]; do
        local success=true
        
        if [ ! -f "$target_path" ]; then
            local upload_output
            if ! upload_output=$(timeout 120 npx clusterioctl --log-level error mod upload "$mod_zip" 2>&1); then
                success=false
                if [ $attempt -eq $max_attempts ]; then
                    local reason="Unknown error (check logs)"
                    if echo "$upload_output" | grep -q "Invalid dependency prefix"; then
                        reason=$(echo "$upload_output" | grep "Invalid dependency prefix" | head -1 | sed 's/.*Invalid dependency prefix: //')
                    elif echo "$upload_output" | grep -q "Unknown version equality"; then
                        reason=$(echo "$upload_output" | grep "Unknown version equality" | head -1 | sed 's/.*Unknown version equality: //')
                    fi
                    
                    echo "✗ ${filename} - ${reason}"
                    echo "${filename}|${reason}" >> /tmp/clusterio_failed_mods
                    return 1
                else
                     echo "  ⚠ Upload failed for ${filename}, retrying..."
                fi
            else
                echo "✓ ${filename} (uploaded)"
            fi
        else
            if [ $attempt -eq 1 ]; then
                echo "✓ ${filename} (already present)"
            fi
        fi

        if [ "$success" = true ]; then
            local without_ext="${filename%.zip}"
            local mod_version="${without_ext##*_}"
            local mod_name="${without_ext%_*}"
            echo "${mod_name}:${mod_version}" >> /tmp/clusterio_uploaded_mods
            return 0
        fi

        sleep 2
        attempt=$((attempt + 1))
    done
    
    return 1
}

add_mod_to_pack_if_missing() {
    local mod_name="$1"
    local mod_version="$2"
    local mod_pack_name="$3"

    if [ -z "$mod_pack_name" ]; then
        echo "Warning: Mod pack name not provided; cannot add ${mod_name}"
        return
    fi

    local pack_state
    pack_state=$(timeout 10 npx clusterioctl --log-level error mod-pack show "$mod_pack_name" 2>/dev/null || true)
    if echo "$pack_state" | grep -F "${mod_name} ${mod_version}" >/dev/null 2>&1; then
        echo "Mod ${mod_name} ${mod_version} already present in ${mod_pack_name}"
        return
    fi

    if run_quiet "Add ${mod_name} ${mod_version} to ${mod_pack_name}" \
        timeout 15 npx clusterioctl --log-level error mod-pack edit "$mod_pack_name" --add-mods "${mod_name}:${mod_version}" --enable-mods "$mod_name"; then
        return
    fi
    echo "Warning: Failed to add ${mod_name} to ${mod_pack_name}"
}

seed_mod_pack_mods() {
    if [ -z "$MOD_PACK_ID" ]; then
        echo "Skipping mod upload; mod pack ID unavailable."
        return
    fi

    if [ ! -d "$SEED_MODS_DIR" ]; then
        echo "Seed mods directory ${SEED_MODS_DIR} not found; nothing to upload."
        return
    fi

    local -a mod_archives=()

    shopt -s nullglob
    local seed_zip
    for seed_zip in "${SEED_MODS_DIR}"/*.zip; do
        mod_archives+=("$seed_zip")
    done
    shopt -u nullglob

    local total_mods=${#mod_archives[@]}
    if [ $total_mods -eq 0 ]; then
        echo "No seed mod archives found under ${SEED_MODS_DIR}. Drop .zip files there to auto-upload them."
        return
    fi

    echo "Uploading ${total_mods} mods..."
    echo ""
    
    : > /tmp/clusterio_uploaded_mods
    : > /tmp/clusterio_failed_mods
    
    local mod_zip
    local batch_pids=()
    local BATCH_SIZE=15
    
    for mod_zip in "${mod_archives[@]}"; do
        upload_mod_only "$mod_zip" &
        batch_pids+=($!)

        if [ ${#batch_pids[@]} -ge $BATCH_SIZE ]; then
            wait
            batch_pids=()
        fi
    done
    
    wait
    
    local uploaded_count=0
    if [ -f /tmp/clusterio_uploaded_mods ]; then
        uploaded_count=$(wc -l < /tmp/clusterio_uploaded_mods)
    fi
    
    echo ""
    echo "Upload completed: ${uploaded_count}/${total_mods} mods."

    if [ $uploaded_count -gt 0 ]; then
        echo "Adding mods to pack '${MOD_PACK_NAME}'..."
        
        local add_args=()
        while read -r mod_entry; do
            if [ -n "$mod_entry" ]; then
                 local m_name="${mod_entry%:*}"
                 add_args+=("--add-mods" "$mod_entry" "--enable-mods" "$m_name")
            fi
        done < /tmp/clusterio_uploaded_mods
        
        local chunk_size=20
        local chunk_args=()
        local count=0
        
        for ((i=0; i<${#add_args[@]}; i+=4)); do
             chunk_args+=("${add_args[i]}" "${add_args[i+1]}" "${add_args[i+2]}" "${add_args[i+3]}")
             count=$((count + 1))
             
             if [ $count -ge $chunk_size ]; then
                  echo "  Applying batch of $count mods to pack..."
                  timeout 60 npx clusterioctl --log-level error mod-pack edit "$MOD_PACK_NAME" "${chunk_args[@]}" >/dev/null 2>&1 || true
                  chunk_args=()
                  count=0
             fi
        done
        
        if [ ${#chunk_args[@]} -gt 0 ]; then
             echo "  Applying remaining $count mods to pack..."
             timeout 60 npx clusterioctl --log-level error mod-pack edit "$MOD_PACK_NAME" "${chunk_args[@]}" >/dev/null 2>&1 || true
        fi
        echo "Mod pack update complete."
    fi

    if [ -f /tmp/clusterio_failed_mods ] && [ -s /tmp/clusterio_failed_mods ]; then
        echo ""
        echo "Failed uploads:"
        while IFS='|' read -r fname reason; do
            echo "  - ${fname}: ${reason}"
        done < /tmp/clusterio_failed_mods
    fi
}

enable_builtin_dlc_mods() {
    local pack_name="$1"
    if [ -z "$pack_name" ]; then
        echo "Skipping built-in DLC enablement; mod pack name missing."
        return
    fi

    echo "Enabling built-in DLC mods in ${pack_name}..."
    
    if timeout 15 npx clusterioctl --log-level error mod-pack edit "$pack_name" \
            --add-mods space-age:2.0.0 --enable-mods space-age \
            --add-mods quality:2.0.0 --enable-mods quality \
            --add-mods elevated-rails:2.0.0 --enable-mods elevated-rails; then
        echo "[OK] All DLCs enabled (space-age, quality, elevated-rails)"
    else
        echo "[WARN] Failed to enable DLCs"
    fi
}

get_mod_pack_id() {
    local pack_name="$1"
    local list_output
    list_output=$(timeout 10 npx clusterioctl --log-level error mod-pack list 2>/dev/null || true)
    if [ -z "$list_output" ]; then
        echo ""
        return
    fi
    echo "$list_output" | awk -F'|' -v target="$pack_name" '
        index($0, "|") {
            name=$2; gsub(/^ +| +$/, "", name);
            id=$1; gsub(/^ +| +$/, "", id);
            if (name == target) {
                print id;
                exit;
            }
        }
    '
}

wait_for_host_connection() {
    local host_name="$1"
    local max_attempts="${2:-60}"
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        local list_output
        list_output=$(timeout 10 npx clusterioctl --log-level error host list 2>/dev/null || true)
        if [ -n "$list_output" ]; then
            local connected
            connected=$(echo "$list_output" | awk -F'|' -v target="$host_name" '
                index($0, "|") {
                    name=$2; gsub(/^ +| +$/, "", name);
                    conn=$4; gsub(/^ +| +$/, "", conn);
                    if (name == target) {
                        print conn;
                        exit;
                    }
                }
            ')
            if [ "$connected" = "true" ]; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

install_mounted_plugins() {
    echo "Scanning for mounted plugins..."
    
    if [ ! -d "${PLUGINS_DIR}" ] || [ -z "$(ls -A ${PLUGINS_DIR} 2>/dev/null)" ]; then
        echo "No plugins found in ${PLUGINS_DIR}"
        return
    fi
    
    for plugin_dir in "${PLUGINS_DIR}"/*; do
        if [ -d "$plugin_dir" ]; then
            plugin_name=$(basename "$plugin_dir")
            echo "Installing plugin: ${plugin_name}"
            if npx clusterioctl plugin add "$plugin_dir" 2>&1 | grep -qE "(Successfully|already)"; then
                echo "✓ ${plugin_name} installed"
            else
                echo "⚠ Warning: Failed to install ${plugin_name}"
            fi
        fi
    done
}

CONTROL_CONFIG_EXISTS=false

echo "=========================================="
echo "Clusterio Cluster Initialization"
echo "=========================================="

# Wait for controller to be ready
echo "Waiting for controller to be ready..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if curl -sf "${CONTROLLER_URL}" > /dev/null 2>&1; then
        echo "Controller is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts - Controller not ready, waiting..."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: Controller did not become ready in time"
    exit 1
fi

# Check if already initialized
if [ -f "$CONFIG_CONTROL" ]; then
    CONTROL_CONFIG_EXISTS=true
    echo ""
    echo "Existing control config detected. Verifying current cluster state..."
fi

echo ""
echo "Preparing control config for admin user..."
cd $CLUSTERIO_DIR

if [ "$CONTROL_CONFIG_EXISTS" = true ]; then
    echo "Control config already exists at $CONFIG_CONTROL (skipping creation)."
else
    echo "Generating control config for admin user..."
    run_quiet "Create ctl config" npx clusteriocontroller --log-level error bootstrap create-ctl-config admin
fi

echo ""
echo "Configuring controller URL..."
run_quiet "Set controller URL" npx clusterioctl --log-level error control-config set control.controller_url "$CONTROLLER_URL"

echo ""
echo "=========================================="
echo "Creating Instances"
echo "=========================================="

# Create instance 1
if timeout 10 npx clusterioctl --log-level error instance list 2>/dev/null | grep -q "clusterio-host-1-instance-1"; then
    echo "Instance clusterio-host-1-instance-1 already exists, skipping creation"
else
    echo "Creating instance: clusterio-host-1-instance-1"
    run_quiet "Create clusterio-host-1-instance-1" timeout 30 npx clusterioctl --log-level error instance create clusterio-host-1-instance-1 --id 1
fi

# Create instance 2
if timeout 10 npx clusterioctl --log-level error instance list 2>/dev/null | grep -q "clusterio-host-2-instance-1"; then
    echo "Instance clusterio-host-2-instance-1 already exists, skipping creation"
else
    echo "Creating instance: clusterio-host-2-instance-1"
    run_quiet "Create clusterio-host-2-instance-1" timeout 30 npx clusterioctl --log-level error instance create clusterio-host-2-instance-1 --id 2
fi

echo ""
echo "Configuring instances..."

# Configure instance 1
(
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.game_port ${HOST1_INSTANCE1_GAME_PORT} &&
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.rcon_port ${HOST1_INSTANCE1_RCON_PORT} &&
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.rcon_password "${RCON_PASSWORD}" &&
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.enable_save_patching true &&
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.settings '{"name":"Clusterio Host 1 - Instance 1","description":"Clusterio cluster - Host 1","auto_pause":false}' &&
  npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.sync_adminlist "bidirectional" &&
  if [ "${FACTORIO_AUTO_START:-false}" = "true" ]; then
    npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 instance.auto_start true
  fi
  echo "[OK] Configured clusterio-host-1-instance-1"
) &
INSTANCE1_PID=$!

# Configure instance 2
(
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.game_port ${HOST2_INSTANCE1_GAME_PORT} &&
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.rcon_port ${HOST2_INSTANCE1_RCON_PORT} &&
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.rcon_password "${RCON_PASSWORD}" &&
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.enable_save_patching true &&
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.settings '{"name":"Clusterio Host 2 - Instance 1","description":"Clusterio cluster - Host 2","auto_pause":false}' &&
  npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.sync_adminlist "bidirectional" &&
  if [ "${FACTORIO_AUTO_START:-false}" = "true" ]; then
    npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 instance.auto_start true
  fi
  echo "[OK] Configured clusterio-host-2-instance-1"
) &
INSTANCE2_PID=$!

wait $INSTANCE1_PID $INSTANCE2_PID

echo ""
echo "=========================================="
echo "Creating Host Configs"
echo "=========================================="

# Create host config for host-1
if [ -f "${HOSTS_DIR}/clusterio-host-1/config-host.json" ]; then
    echo "Host config for clusterio-host-1 already exists"
else
    echo "Creating host config: clusterio-host-1"
    run_quiet "Create host config clusterio-host-1" \
        timeout 30 npx clusterioctl --log-level error host create-config \
            --name clusterio-host-1 \
            --id 1 \
            --generate-token \
            --output "${HOSTS_DIR}/clusterio-host-1/config-host.json"
fi

# Create host config for host-2
if [ -f "${HOSTS_DIR}/clusterio-host-2/config-host.json" ]; then
    echo "Host config for clusterio-host-2 already exists"
else
    echo "Creating host config: clusterio-host-2"
    run_quiet "Create host config clusterio-host-2" \
        timeout 30 npx clusterioctl --log-level error host create-config \
            --name clusterio-host-2 \
            --id 2 \
            --generate-token \
            --output "${HOSTS_DIR}/clusterio-host-2/config-host.json"
fi

echo ""
echo "Configuring host connection settings..."

if [ -f "${HOSTS_DIR}/clusterio-host-1/config-host.json" ]; then
    sed -i "s|http://localhost:8080/|${CONTROLLER_URL}|" "${HOSTS_DIR}/clusterio-host-1/config-host.json"
    echo "[OK] Updated clusterio-host-1 controller URL"
fi

if [ -f "${HOSTS_DIR}/clusterio-host-2/config-host.json" ]; then
    sed -i "s|http://localhost:8080/|${CONTROLLER_URL}|" "${HOSTS_DIR}/clusterio-host-2/config-host.json"
    echo "[OK] Updated clusterio-host-2 controller URL"
fi

# Create admin users
if [ -n "${FACTORIO_ADMINS}" ]; then
    echo ""
    echo "Creating Factorio admin users: ${FACTORIO_ADMINS}"
    IFS=',' read -ra ADMIN_ARRAY <<< "${FACTORIO_ADMINS}"
    for admin_name in "${ADMIN_ARRAY[@]}"; do
        admin_name=$(echo "$admin_name" | xargs)
        if [ -n "$admin_name" ]; then
            (
                if npx clusterioctl --log-level error user set-admin "$admin_name" --create 2>/dev/null; then
                    echo "[OK] Set $admin_name as admin"
                else
                    echo "[WARN] Failed to set admin for $admin_name"
                fi
            ) &
        fi
    done
    wait
fi

echo ""
echo "=========================================="
echo "Installing Plugins"
echo "=========================================="

install_mounted_plugins

echo ""
echo "=========================================="
echo "Building and Uploading clusterio_lib"
echo "=========================================="

if [ ! -f "/usr/lib/node_modules/@clusterio/host/dist/clusterio_lib_2.0.20.zip" ]; then
    echo "Building clusterio_lib Factorio mod..."
    cd /usr/lib/node_modules/@clusterio/host
    npm run build-mod -- --output-dir ./dist 2>&1 | grep -i "Writing dist" && echo "✓ clusterio_lib built" || echo "Warning: Failed to build clusterio_lib"
    cd $CLUSTERIO_DIR
else
    echo "✓ clusterio_lib already built"
fi

echo ""
echo "=========================================="
echo "Setting up Mod Pack"
echo "=========================================="

MOD_PACK_ID=$(get_mod_pack_id "$MOD_PACK_NAME")
if [ -z "$MOD_PACK_ID" ]; then
    echo "Creating mod pack '$MOD_PACK_NAME' for Factorio ${MOD_PACK_FACTORIO_VERSION}..."
    run_quiet "Create mod pack $MOD_PACK_NAME" timeout 15 npx clusterioctl --log-level error mod-pack create "$MOD_PACK_NAME" "$MOD_PACK_FACTORIO_VERSION"
    MOD_PACK_ID=$(get_mod_pack_id "$MOD_PACK_NAME")
else
    echo "Mod pack '$MOD_PACK_NAME' already exists (ID: $MOD_PACK_ID)"
fi

if [ -n "$MOD_PACK_ID" ]; then
    # Upload clusterio_lib
    echo "Uploading clusterio_lib..."
    if ! npx clusterioctl --log-level error mod list 2>&1 | grep -q "clusterio_lib.*2.0.20"; then
        timeout 30 npx clusterioctl --log-level error mod upload /usr/lib/node_modules/@clusterio/host/dist/clusterio_lib_2.0.20.zip && echo "✓ clusterio_lib uploaded" || echo "Warning: Failed to upload clusterio_lib"
    else
        echo "✓ clusterio_lib already uploaded"
    fi
    
    echo ""
    echo "Uploading seed mods..."
    seed_mod_pack_mods
    
    enable_builtin_dlc_mods "$MOD_PACK_NAME"
    
    echo "Adding clusterio_lib to mod pack..."
    add_mod_to_pack_if_missing "clusterio_lib" "2.0.20" "$MOD_PACK_NAME"
    run_quiet "Enable clusterio_lib" timeout 10 npx clusterioctl --log-level error mod-pack edit "$MOD_PACK_NAME" --enable-mods "clusterio_lib" || true

    echo "Assigning mod pack to instances..."
    (run_quiet "Set mod pack for instance 1" timeout 10 npx clusterioctl --log-level error instance config set clusterio-host-1-instance-1 factorio.mod_pack_id "$MOD_PACK_ID" || true) &
    (run_quiet "Set mod pack for instance 2" timeout 10 npx clusterioctl --log-level error instance config set clusterio-host-2-instance-1 factorio.mod_pack_id "$MOD_PACK_ID" || true) &
    wait
fi

echo ""
echo "=========================================="
echo "Assigning Instances to Hosts"
echo "=========================================="

echo "Waiting for hosts to connect..."
HOST1_READY=false
HOST2_READY=false

(wait_for_host_connection clusterio-host-1 90 && touch /tmp/host1_ready) &
(wait_for_host_connection clusterio-host-2 90 && touch /tmp/host2_ready) &
wait

[ -f /tmp/host1_ready ] && HOST1_READY=true && rm -f /tmp/host1_ready && echo "clusterio-host-1 connected"
[ -f /tmp/host2_ready ] && HOST2_READY=true && rm -f /tmp/host2_ready && echo "clusterio-host-2 connected"

if [ "$HOST1_READY" = true ]; then
    echo "Assigning instance 1 to host 1..."
    if run_quiet "Assign instance 1" timeout 15 npx clusterioctl --log-level error instance assign clusterio-host-1-instance-1 clusterio-host-1; then
        # Seed saves
        INSTANCE1_SAVES_DIR="${HOSTS_DIR}/clusterio-host-1/instances/clusterio-host-1-instance-1/saves"
        if [ -d "${SEED_SAVES_DIR}" ] && [ -n "$(ls -A ${SEED_SAVES_DIR} 2>/dev/null)" ]; then
            mkdir -p "${INSTANCE1_SAVES_DIR}"
            cp -n ${SEED_SAVES_DIR}/*.zip "${INSTANCE1_SAVES_DIR}/" 2>/dev/null || true
            chown -R 999:999 "$(dirname "${INSTANCE1_SAVES_DIR}")"
            
            SAVE_FILE=""
            if [ -n "${INSTANCE1_SAVE_NAME}" ] && [ -f "${INSTANCE1_SAVES_DIR}/${INSTANCE1_SAVE_NAME}" ]; then
                SAVE_FILE="${INSTANCE1_SAVES_DIR}/${INSTANCE1_SAVE_NAME}"
            else
                SAVE_FILE=$(ls -t "${INSTANCE1_SAVES_DIR}"/*.zip 2>/dev/null | head -n 1)
            fi
            [ -n "$SAVE_FILE" ] && touch "$SAVE_FILE"
            echo "Saves seeded for instance 1"
        fi
    fi
fi

if [ "$HOST2_READY" = true ]; then
    echo "Assigning instance 2 to host 2..."
    if run_quiet "Assign instance 2" timeout 15 npx clusterioctl --log-level error instance assign clusterio-host-2-instance-1 clusterio-host-2; then
        # Seed saves
        INSTANCE2_SAVES_DIR="${HOSTS_DIR}/clusterio-host-2/instances/clusterio-host-2-instance-1/saves"
        if [ -d "${SEED_SAVES_DIR}" ] && [ -n "$(ls -A ${SEED_SAVES_DIR} 2>/dev/null)" ]; then
            mkdir -p "${INSTANCE2_SAVES_DIR}"
            cp -n ${SEED_SAVES_DIR}/*.zip "${INSTANCE2_SAVES_DIR}/" 2>/dev/null || true
            chown -R 999:999 "$(dirname "${INSTANCE2_SAVES_DIR}")"
            
            SAVE_FILE=""
            if [ -n "${INSTANCE2_SAVE_NAME}" ] && [ -f "${INSTANCE2_SAVES_DIR}/${INSTANCE2_SAVE_NAME}" ]; then
                SAVE_FILE="${INSTANCE2_SAVES_DIR}/${INSTANCE2_SAVE_NAME}"
            else
                SAVE_FILE=$(ls -t "${INSTANCE2_SAVES_DIR}"/*.zip 2>/dev/null | head -n 1)
            fi
            [ -n "$SAVE_FILE" ] && touch "$SAVE_FILE"
            echo "Saves seeded for instance 2"
        fi
    fi
fi

echo ""
echo "=========================================="
echo "Cluster Initialization Complete!"
echo "=========================================="
echo ""

# Display versions
CLUSTERIO_VERSION=$(npx clusterioctl --version 2>/dev/null | head -1 || echo "unknown")
FACTORIO_VERSION=$(/factorio/bin/x64/factorio --version 2>/dev/null | grep -oP 'Version: \K[0-9.]+' | head -1 || echo "$MOD_PACK_FACTORIO_VERSION")
echo "Clusterio: $CLUSTERIO_VERSION"
echo "Factorio:  $FACTORIO_VERSION"

# Display admin token
ADMIN_TOKEN=""
if [ -f "$CONFIG_CONTROL" ]; then
    ADMIN_TOKEN=$(grep '"control.controller_token"' "$CONFIG_CONTROL" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
fi

echo ""
if [ -n "$ADMIN_TOKEN" ]; then
    echo "Admin Token: ${ADMIN_TOKEN}"
else
    echo "Admin Token: (see data/controller/config-control.json)"
fi

echo ""
echo "Web UI: http://localhost:${CONTROLLER_HTTP_PORT}"
echo ""
echo "Hierarchy:"
echo "  Controller"
echo "    ├─→ clusterio-host-1"
echo "    │     └─→ clusterio-host-1-instance-1 (Game: ${HOST1_INSTANCE1_GAME_PORT}, RCON: ${HOST1_INSTANCE1_RCON_PORT})"
echo "    └─→ clusterio-host-2"
echo "          └─→ clusterio-host-2-instance-1 (Game: ${HOST2_INSTANCE1_GAME_PORT}, RCON: ${HOST2_INSTANCE1_RCON_PORT})"
echo ""

echo "Starting all instances..."
timeout 30 npx clusterioctl --log-level error instance start-all 2>&1 | grep -v "already running" || true
echo "Instances started"

