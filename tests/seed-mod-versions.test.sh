#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/mods"
export CALL_LOG="$WORK/calls.jsonl"
cat > "$WORK/bin/gosu" <<'SH'
#!/bin/bash
shift
exec "$@"
SH
cat > "$WORK/bin/npx" <<'SH'
#!/bin/bash
node - "$@" <<'JS'
require("node:fs").appendFileSync(process.env.CALL_LOG, JSON.stringify(process.argv.slice(2)) + "\n");
JS
SH
chmod +x "$WORK/bin/gosu" "$WORK/bin/npx"
export PATH="$WORK/bin:$PATH"
sed "s|SEED_MODS_DIR=\"/clusterio/seed-data/mods\"|SEED_MODS_DIR=\"$WORK/mods\"|" \
  "$REPO_ROOT/scripts/seed-mods.sh" > "$WORK/seeder.sh"

for zip in ore_tools_1.9.0 ore_tools_1.10.0 patch_0.1.9 patch_0.1.10 major_9.0.0 major_10.0.0 \
  Same_1.0.0 same_2.0.0 only_1.2.3 forward_1.2.0 forward_1.3.0; do
  touch "$WORK/mods/$zip.zip"
done

for attempt in 1 2; do
  : > "$CALL_LOG"
  bash "$WORK/seeder.sh" "$WORK/control.json" 42
  node - <<'JS'
const assert = require("node:assert/strict");
const calls = require("node:fs").readFileSync(process.env.CALL_LOG, "utf8").trim().split("\n").map(JSON.parse);
assert.equal(calls.filter(args => args.includes("upload")).length, 11);
const edits = calls.filter(args => args.includes("edit"));
assert.equal(edits.length, 1);
const args = edits[0];
assert.deepEqual(args.slice(args.indexOf("--add-mods") + 1, args.indexOf("--config")).sort(),
  ["Same:1.0.0", "forward:1.3.0", "major:10.0.0", "only:1.2.3", "ore_tools:1.10.0", "patch:0.1.10", "same:2.0.0"]);
JS
  echo "PASS numeric major/minor/patch selection, exact names, upload retention, run $attempt"
done

: > "$CALL_LOG"
bash "$WORK/seeder.sh" "$WORK/control.json" ""
node - <<'JS'
const assert = require("node:assert/strict");
const calls = require("node:fs").readFileSync(process.env.CALL_LOG, "utf8").trim().split("\n").map(JSON.parse);
assert.equal(calls.filter(args => args.includes("upload")).length, 11);
assert.equal(calls.filter(args => args.includes("edit")).length, 0);
JS
echo "PASS uploads without a default mod pack"
