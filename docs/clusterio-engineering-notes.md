# Clusterio engineering notes — upstream behaviors these images build around

Clusterio is **alpha software under active, generous development** — this document is not a
complaint list. It records runtime behaviors that repeatedly surprised us (and both production
consumers of these images), what the images do about each, and where an upstream contribution
would dissolve the workaround entirely. Every entry was paid for with real debugging time; the
point of writing them down is that nobody pays twice — and that when we open upstream PRs, the
evidence is already assembled.

Status legend: 🛡 = handled by these images · 📝 = documented protocol · ⬆ = upstream
contribution candidate (tracked in #17).

## Process & lifecycle

### 1. Instance auto-start races the controller handshake (🛡 ⬆)
An instance that starts before its host completes the controller handshake **silently skips
instance plugins** — no error, IPC goes nowhere. Everything looks alive.
**Images**: the host entrypoint's *boot-race guard* restarts any instance whose `startedAtMs`
predates the handshake. **Upstream candidate**: fail loud (minimum) or gate auto-start on plugin
registry readiness (#17).

### 2. Plugin Node code is cached for the host process's lifetime (📝 ⬆)
`instance stop/start` re-patches the save-embedded **Lua** module but never reloads plugin
**Node** code — the require cache serves the old build, while logging "plugin initialized" from
the stale class. Cost one consumer a full evening.
**Images**: documented deploy protocol (restart the *host container*, then verify a
new-code-only behavior) in [plugin-development.md](plugin-development.md). **Upstream
candidate**: report loaded plugin version/build per host (would make deploy-freshness checks
generic instead of every plugin hand-rolling a build stamp).

### 3. Lua modules are save-patched (📝)
Module code lives inside the save file; it goes live only when Clusterio re-patches the save
(instance restart). A plain container restart can reuse the previously patched `script.dat`.
Not a bug — a design with non-obvious deploy consequences. Documented in the plugin guide.

## Tooling

### 4. `clusterioctl` has no client-side timeout (🛡)
Against an unreachable, or reachable-but-mid-boot, controller, `clusterioctl` **hangs
indefinitely** rather than failing. A frozen call in a poll loop produces eternal silence — it
can't even reach its own deadline check (found via #24's instrumentation).
**Images**: every scripted `clusterioctl` invocation is wrapped in `timeout`. **Rule for this
repo**: no unbounded ctl calls in entrypoints, healthchecks, or CI, ever.

### 5. `create-ctl-config` bakes a controller-local URL (🛡)
The generated `config-control.json` carries `control.controller_url=http://localhost:8080/` —
correct where it's generated, a **self-dial** from any other container. Combined with #4, a
host using the shared config hangs forever instead of erroring.
**Images**: cross-container consumers (the boot-race guard) derive a host-reachable copy,
rewriting `controller_url` to the cluster-internal address. Validated against a live cluster:
instant table with the rewrite, 25 s hang-to-timeout without.

### 6. The controller serves non-hashed `/static` assets as `immutable, max-age=1y` (🛡 ⬆)
Module-Federation entries/manifests and commonly fixed-name plugin chunks get pinned by
returning browsers for a year — stale web UI after every upgrade. One consumer shipped a
boot-time monkeypatch of `Controller.js` for this.
**Images**: the patch is absorbed and env-gated (`CONTROLLER_STATIC_CACHE_MODE`, default
`revalidate`); no-ops gracefully if core changes. **Upstream candidate**: serve non-hashed
assets with revalidation.

## Versioning & packaging

### 7. The npm release can lag the fork's Factorio-version support (🛡)
Empirically at alpha.26: 2.1-format mod `info.json` is rejected (`Mod's info.json is not
valid` — the lenient-parsing fix was merged upstream 9 days after the alpha shipped) and the
`recycler` builtin is absent. Real Factorio 2.1 support lived only in the fork's
`factorio-2.1.8` branch.
**Images**: `factorio-*` branches (and PRs into them) build the `custom` target from the
matching fork branch; the DLC enable is non-fatal-but-loud on cores missing a builtin;
dual-axis tags + `BUILD_INFO` make which-core-am-I-running a query.
**Reactivation trigger FIRED (2026-07-22):** npm **`2.0.0-alpha.27`** now carries the full 2.1
support — `ApiVersions` `2.1`, the 2.1 default packs + `recycler` builtin, lenient mod-version
parsing, and the previously fork-only `clusterio_lib` `factorio_version: "2.1"` variant (v2.0.21).
CI proved it end-to-end on the `release` target (probe PR #39: "Space Age 2.1" mod pack seeded,
instances reached `running`, idempotent restart). So the active line moved to **`main`** on the
`release` (npm) target, and the `custom`/fork machinery is now **dormant** — kept intact for the
next Factorio line that npm may lag: branch `factorio-<X.Y>` off `main` and CI builds it from the
matching fork branch automatically. The `factorio-2.1.8` branch is archived. (The alpha.26 history
above is retained as the record of *why* the fork existed.)

### 8. Duplicate `@clusterio/lib` is fatal, and npm plants duplicates by default (🛡 📝)
Clusterio (correctly) enforces a singleton `@clusterio/lib` — but npm 7+ auto-installs
peerDependencies, so a routine `npm install` inside a mounted plugin dir crashes every
`clusterioctl` invocation cluster-wide.
**Images**: the entrypoint strips stray `@clusterio/*` from each external plugin on **every
boot** (logged); the plugin guide documents `.npmrc legacy-peer-deps=true` plus two proven
workstation patterns (repo-root devDeps; isolated-container builds).

### 9. Custom builds track the fork branch tip (📝)
The `custom` target clones the fork branch at build time (`--depth 1`) — there is no
commit-level pin in this repo, so two `custom` builds of the same docker-repo commit can embed
different core code. Mitigation: `BUILD_INFO.gitSha` records the *docker repo* commit, and the
build logs record the clone; full reproducibility would need recording the fork commit too
(candidate: add the fork SHA to `BUILD_INFO`).

## Game/server semantics

### 10. Headless servers pause at 0 players, freezing plugin pipelines (📝)
`auto_pause` defaults true; a paused game stops `on_tick` — every tick-driven plugin queue
silently stalls **while RCON keeps answering**, so the cluster looks healthy. Both production
consumers independently discovered and seeded around this.
**Images**: documented ([seed-data.md](seed-data.md), README troubleshooting); the seeder logs
an INFO when an instance is created without an explicit setting.

### 11. Plugin logger output goes to files, not container stdout (📝 → 🛡 planned)
`this.logger.*` lands in `/clusterio/logs/{cluster,host}/*.log`, so `docker logs` shows nothing
from plugins — called "the #1 gotcha that wastes hours" by one consumer, which built a whole
tool around reading the files. **Planned** (#19): env-gated streaming to stdout.

---

*When adding an entry: neutral description of the behavior, why it surprises, what the images
do, upstream status. Keep the tone factual — these notes double as the evidence base for
upstream PRs, and they should read as a contribution map, not a grievance list.*
