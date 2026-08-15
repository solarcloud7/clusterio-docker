#!/bin/bash
# seed-instances-order.test.sh
#
# Pins the one ordering property that keeps first-run seeding from killing a host
# process: seeding must never push instance config to an ALREADY-ASSIGNED instance.
#
# Why that is the property (see the block comment in scripts/seed-instances.sh):
# the controller turns `instance config set` into an InstanceAssignInternalRequest,
# the host applies it with notify=true, and a changed `factorio.settings` reaches
# FactorioServer.dataPath() — which is path.join(null, …) until FactorioServer.init()
# resolves. An unhandled rejection there takes clusteriohost down. While the instance
# is unassigned no host holds it, so no listener exists for the emit to reach.
#
# The whole run is stubbed: `npx` and `gosu` are shimmed onto PATH and every
# clusterioctl invocation is recorded to a call log. No Docker, no cluster, no
# network — this belongs in the cheap `gates` CI job.
#
# requires: bash, node (for seed-instances.sh's own instance.json parsing), coreutils
# produces: exit 0 when the ordering property holds, exit 1 with the call log dumped
# does not: exercise the controller, the host, or any real clusterioctl behaviour —
#           it asserts what the SCRIPT issues and in what order, nothing about what
#           Clusterio does with those calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_SCRIPT="$REPO_ROOT/scripts/seed-instances.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

# ---------------------------------------------------------------------------
# The order checker, used against both a real run and hand-written logs.
#
# Kept separate from the run so the negative cases below can prove it has teeth:
# a checker that cannot fail is indistinguishable from no checker at all.
# ---------------------------------------------------------------------------
# `|| true`: "no such call" is an ANSWER here, not an error. Under `set -e` +
# pipefail a non-matching grep would abort the test instead of letting the
# presence checks below report which call is missing.
first_line() { grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 || true; }
last_line()  { grep -nF -- "$2" "$1" 2>/dev/null | tail -1 | cut -d: -f1 || true; }

# check_order <log> <instance-name> <expect-config: yes|no>
# Echoes the reasons it rejected the log; returns 0 only if every rule holds.
check_order() {
  local log="$1" name="$2" expect_config="$3"
  local create assign upload start last_config rc=0

  create=$(first_line "$log" "instance create $name")
  assign=$(first_line "$log" "instance assign $name")
  upload=$(first_line "$log" "instance save upload $name")
  start=$(first_line "$log" "instance start $name")
  last_config=$(last_line "$log" "instance config set $name")

  # Presence first. Without this an empty or mis-shimmed log satisfies every
  # ordering comparison below by having nothing to compare, and the test passes
  # while measuring nothing.
  for req in create:"$create" assign:"$assign" upload:"$upload" start:"$start"; do
    if [ -z "${req#*:}" ]; then
      echo "  no '${req%%:*}' call recorded for $name"
      rc=1
    fi
  done
  if [ "$expect_config" = "yes" ] && [ -z "$last_config" ]; then
    echo "  no 'instance config set' recorded for $name (instance.json was not applied)"
    rc=1
  fi
  [ "$rc" -eq 0 ] || return 1

  # The property: every config push precedes the assign.
  if [ -n "$last_config" ] && [ "$last_config" -gt "$assign" ]; then
    echo "  config set for $name at line $last_config is AFTER assign at line $assign"
    rc=1
  fi
  # Ordering that must survive the reorder: create first, and upload/start after
  # assign (both need an assigned host).
  [ "$create" -lt "$assign" ] || { echo "  create ($create) is not before assign ($assign)"; rc=1; }
  [ "$upload" -gt "$assign" ] || { echo "  save upload ($upload) is not after assign ($assign)"; rc=1; }
  [ "$start" -gt "$upload" ]  || { echo "  start ($start) is not after save upload ($upload)"; rc=1; }
  return "$rc"
}

# ---------------------------------------------------------------------------
# Case 1 — a real run of scripts/seed-instances.sh against shimmed tooling
# ---------------------------------------------------------------------------
echo "=== Case 1: real seed-instances.sh run, clusterioctl shimmed ==="

CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"

mkdir -p "$WORK/bin"

# gosu runs a command as another user; here it just drops the user argument.
cat > "$WORK/bin/gosu" <<'SH'
#!/bin/bash
shift
exec "$@"
SH

# clusterioctl stand-in. Records every invocation, and answers `instance list`
# with clusterioctl's real table shape (name in column 1, status in column 5,
# no leading pipe) so the script's own awk/grep parsing is exercised as written.
cat > "$WORK/bin/npx" <<'SH'
#!/bin/bash
if [ "${1:-}" != "clusterioctl" ]; then
  exec command npx "$@"
fi
shift
printf '%s\n' "$*" >> "$CALL_LOG"

args="$*"
case "$args" in
  *"instance list"*)
    echo "name         | id    | assignedHost | gamePort | status  | factorioVersion | startedAtMs | updatedAtMs | excludeFromStartAll"
    echo "---------------------------------------------------------------------------------------------------------------------------"
    while IFS= read -r line; do
      case "$line" in
        *"instance create "*)
          n="${line##*instance create }"; n="${n%% *}"
          status=stopped
          grep -qF "instance start $n" "$CALL_LOG" && status=running
          printf '%-12s | %-5s | %-12s | %-8s | %-7s | %-15s | %-11s | %-11s | %s\n' \
            "$n" 1 1 34100 "$status" 2.1.11 1 1 false
          ;;
      esac
    done < "$CALL_LOG"
    ;;
esac
exit 0
SH

chmod +x "$WORK/bin/gosu" "$WORK/bin/npx"

# Fixture seed tree. AutoInstance carries an instance.json (so config IS applied and
# the ordering property has something to violate); NoConfigInstance has none and is
# held stopped, which also exercises the auto_start=false branch.
mkdir -p "$WORK/seed-data/hosts/clusterio-host-1/AutoInstance"
mkdir -p "$WORK/seed-data/hosts/clusterio-host-1/NoConfigInstance"
cat > "$WORK/seed-data/hosts/clusterio-host-1/AutoInstance/instance.json" <<'JSON'
{
	"instance.id": 1234,
	"instance.name": "AutoInstance",
	"instance.assigned_host": 9,
	"instance.auto_start": true,
	"factorio.settings": { "auto_pause": false, "name": "seed order fixture" },
	"factorio.enable_whitelist": false
}
JSON
echo '{"instance.auto_start": false}' > "$WORK/seed-data/hosts/clusterio-host-1/NoConfigInstance/instance.json"
: > "$WORK/seed-data/hosts/clusterio-host-1/AutoInstance/world.zip"
: > "$WORK/seed-data/hosts/clusterio-host-1/NoConfigInstance/world.zip"

echo '{}' > "$WORK/config-control.json"

run_log="$WORK/run.out"
set +e
PATH="$WORK/bin:$PATH" CALL_LOG="$CALL_LOG" SEED_DATA_DIR="$WORK/seed-data" \
  bash "$SEED_SCRIPT" "$WORK/config-control.json" 0 > "$run_log" 2>&1
run_rc=$?
set -e

if [ "$run_rc" -ne 0 ]; then
  fail "seed-instances.sh exited $run_rc under the stubs"
  sed 's/^/    /' "$run_log" >&2
else
  pass "seed-instances.sh completed under the stubs"
fi

echo "--- recorded clusterioctl calls ---"
sed 's/^/    /' "$CALL_LOG"
echo "-----------------------------------"

if reasons=$(check_order "$CALL_LOG" AutoInstance yes); then
  pass "AutoInstance: every config push precedes assign; upload and start follow it"
else
  fail "AutoInstance ordering violated"
  printf '%s\n' "$reasons" >&2
fi

# The instance held stopped still must not be configured after assign. It has an
# instance.json (auto_start only), so a config push is possible but not required.
if grep -qF "instance start NoConfigInstance" "$CALL_LOG"; then
  fail "NoConfigInstance was started despite instance.auto_start=false"
else
  pass "NoConfigInstance was not started (auto_start=false honoured)"
fi

assign_line=$(first_line "$CALL_LOG" "instance assign NoConfigInstance")
late_config=$(last_line "$CALL_LOG" "instance config set NoConfigInstance")
if [ -z "$assign_line" ]; then
  fail "NoConfigInstance was never assigned — harness did not exercise it"
elif [ -n "$late_config" ] && [ "$late_config" -gt "$assign_line" ]; then
  fail "NoConfigInstance config set at line $late_config is after assign at line $assign_line"
else
  pass "NoConfigInstance: no config push after assign"
fi

# Catch-all over EVERY instance in the fixture, named or not: no config push may
# follow the last assign. The per-instance checks above are the ones with teeth for
# the current single-pass loop; this one is what still covers an instance added to
# the fixture later, or a refactor that batches all assigns ahead of configuration.
last_assign=$(last_line "$CALL_LOG" "instance assign ")
last_any_config=$(last_line "$CALL_LOG" "instance config set ")
if [ -n "$last_any_config" ] && [ -n "$last_assign" ] && [ "$last_any_config" -gt "$last_assign" ]; then
  fail "some 'instance config set' (line $last_any_config) runs after the last assign (line $last_assign)"
else
  pass "no 'instance config set' anywhere after the last assign"
fi

# ---------------------------------------------------------------------------
# Case 2 — the checker rejects the pre-fix order (teeth)
# ---------------------------------------------------------------------------
echo "=== Case 2: checker must reject the pre-fix order ==="
cat > "$WORK/old-order.log" <<'LOG'
--log-level error instance list
--log-level error instance create AutoInstance
--log-level error instance assign AutoInstance 1
--log-level error instance config set AutoInstance factorio.settings {}
--log-level error instance save upload AutoInstance /seed/world.zip
--log-level error instance start AutoInstance
LOG
if check_order "$WORK/old-order.log" AutoInstance yes >/dev/null 2>&1; then
  fail "checker accepted a log with config set AFTER assign — it has no teeth"
else
  pass "checker rejects config set after assign"
fi

# ---------------------------------------------------------------------------
# Case 3 — a silent harness break must be loud, not a vacuous pass
# ---------------------------------------------------------------------------
echo "=== Case 3: empty and partial logs must fail, not pass vacuously ==="
: > "$WORK/empty.log"
if check_order "$WORK/empty.log" AutoInstance yes >/dev/null 2>&1; then
  fail "checker accepted an EMPTY call log"
else
  pass "checker rejects an empty call log"
fi

cat > "$WORK/no-config.log" <<'LOG'
--log-level error instance create AutoInstance
--log-level error instance assign AutoInstance 1
--log-level error instance save upload AutoInstance /seed/world.zip
--log-level error instance start AutoInstance
LOG
if check_order "$WORK/no-config.log" AutoInstance yes >/dev/null 2>&1; then
  fail "checker accepted a log where instance.json was never applied at all"
else
  pass "checker rejects a log with no config push (instance.json silently skipped)"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "seed ordering test: $FAILURES failure(s)" >&2
  exit 1
fi
echo "seed ordering test: all checks passed"
