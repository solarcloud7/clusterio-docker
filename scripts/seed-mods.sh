#!/bin/bash
# seed-mods.sh
# Uploads Factorio mod .zip files from seed-data/mods/ to the controller,
# then adds them to the default mod pack so instances actually load them.
#
# Clusterio mod flow:  Controller → Host (cached on demand) → Instance (symlinked)
# Runs on every controller startup (not just first run) so that new mods added
# to seed-data/mods/ are picked up without requiring a full volume wipe.
# Already-uploaded mods are skipped; already-added mods are idempotent.
#
# Expected arguments:
#   $1 = CONTROL_CONFIG   (path to config-control.json)
#   $2 = MOD_PACK_ID      (optional — default mod pack ID to add mods to)
#
# Reads from: /clusterio/seed-data/mods/*.zip

set -e

CONTROL_CONFIG="$1"
MOD_PACK_ID="$2"
SEED_MODS_DIR="/clusterio/seed-data/mods"

if [ ! -d "$SEED_MODS_DIR" ]; then
  exit 0
fi

# Collect mod zips (ignore .gitkeep and non-zip files)
shopt -s nullglob
MOD_FILES=("$SEED_MODS_DIR"/*.zip)
shopt -u nullglob

if [ ${#MOD_FILES[@]} -eq 0 ]; then
  exit 0
fi

echo "Seeding ${#MOD_FILES[@]} mod(s) to controller..."

# Track mods to add to the mod pack
MODS_TO_ADD=()

for mod_file in "${MOD_FILES[@]}"; do
  mod_filename=$(basename "$mod_file" .zip)
  echo "  Uploading: ${mod_filename}.zip"
  gosu clusterio npx clusterioctl --log-level error mod upload "$mod_file" \
    --config "$CONTROL_CONFIG" 2>/dev/null || {
      echo "    WARNING: Failed to upload ${mod_filename}.zip (may already exist)"
    }

  # Parse mod name and version from filename (Factorio convention: name_version.zip)
  # The last _N.N.N segment is the version; everything before is the mod name.
  if [[ "$mod_filename" =~ ^(.+)_([0-9]+\..+)$ ]]; then
    MODS_TO_ADD+=("${BASH_REMATCH[1]}:${BASH_REMATCH[2]}")
  else
    echo "    WARNING: Could not parse name:version from '$mod_filename' — skipping mod pack add"
  fi
done

# Add all uploaded mods to the default mod pack (if ID was provided)
if [ -n "$MOD_PACK_ID" ] && [ ${#MODS_TO_ADD[@]} -gt 0 ]; then
  echo "Adding ${#MODS_TO_ADD[@]} mod(s) to mod pack $MOD_PACK_ID..."
  gosu clusterio npx clusterioctl --log-level error mod-pack edit "$MOD_PACK_ID" \
    --add-mods "${MODS_TO_ADD[@]}" \
    --config "$CONTROL_CONFIG" 2>/dev/null || {
      echo "  WARNING: Failed to add mods to mod pack (may already be added)"
    }
  echo "  Mods added: ${MODS_TO_ADD[*]}"
fi

echo "Mod seeding complete."
