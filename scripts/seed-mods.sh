#!/bin/bash
# seed-mods.sh
# Uploads Factorio mod .zip files from seed-data/mods/ to the controller.
#
# Clusterio mod flow:  Controller → Host (cached on demand) → Instance (symlinked)
# Runs on every controller startup (not just first run) so that new mods added
# to seed-data/mods/ are picked up without requiring a full volume wipe.
# Already-uploaded mods are skipped.
#
# Expected arguments:
#   $1 = CONTROL_CONFIG  (path to config-control.json)
#
# Reads from: /clusterio/seed-data/mods/*.zip

set -e

CONTROL_CONFIG="$1"
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

for mod_file in "${MOD_FILES[@]}"; do
  mod_name=$(basename "$mod_file")
  echo "  Uploading: $mod_name"
  gosu clusterio npx clusterioctl --log-level error mod upload "$mod_file" \
    --config "$CONTROL_CONFIG" 2>/dev/null || {
      echo "    WARNING: Failed to upload $mod_name (may already exist)"
    }
done

echo "Mod seeding complete."
