# Changelog — image change notices

Every push that changes **image-affecting files** (`Dockerfile.*`, `scripts/`,
`docker-compose*.yml`, `.github/workflows/`) MUST add an entry here — CI's
**changelog gate** fails the build otherwise. Newest first.

The top entry is published to each build's run summary, and images carry
`/clusterio/BUILD_INFO` (`gitSha`), so any running container links back to its
change notice: container → sha → this file.

Format: `## YYYY-MM-DD` heading + short bullets. Always state the Clusterio /
Factorio versions when they change.

## 2026-07-06

- **Discord bridge hardening**: added an opt-in controller-local bridge for the Discord bot, backed by one persistent `@clusterio/lib` Control connection, required bearer token auth, dedicated-network binding (`BRIDGE_BIND_HOST`), optional CIDR allowlisting, request/rate/body/output limits, template-only commands by default, and raw RCON behind `BRIDGE_ALLOW_RAW=true`. The bridge is copied into the controller image but `8100` is not published by compose; docs and CI cover the private-network deployment pattern.
- **Bridge fix + test layer**: fixed a signedness bug in the CIDR allowlist — networks with the first octet ≥ 128 (e.g. `172.31.50.0/24`) never matched and every request got 403. Caught by the new unit tests: pure helpers (auth, CIDR, rate limit, size caps, command templates) now live in `bridge/bridge-lib.mjs` with `node --test` coverage gating CI before the compose stack builds. CI also gained wrong-token 401, rate-limit 429, and bridge-survives-restart checks.
- CI only (no image content change): added silent-degradation tripwires — asserts the
  static-cache patch actually attached and `/static` serves with revalidation (a Clusterio
  bump can remove the protection with no error), asserts `BUILD_INFO.clusterioTarget`
  matches the target CI built, and asserts each host derived its non-overlapping game-port
  range from `HOST_ID` (host N → `34N00-34N99`).

## 2026-07-05

- CI: absorbed `main`'s Node-24 Actions bump (checkout@v6, buildx@v4,
  login@v4, metadata@v6, build-push@v7) — kills the deprecation warnings on
  every run; `main` now holds nothing the active line lacks. No image content
  change.
- **Default branch flipped `main` → `factorio-2.1.8`** (publishing-semantics
  change, no code change): the repo's face (README, issue templates, this
  file) is now the active line, and `latest` + the Clusterio version tag
  publish from its **custom** (fork) builds — `BUILD_INFO.clusterioTarget`
  records which target built any image. `main` is parked as the npm-release
  line until the npm release supports Factorio 2.1 (alpha.26 provably
  doesn't). Branch model documented in README + CONTRIBUTING.
- **Observability: plugin logs stream to stdout** — the on-disk cluster/host
  JSON logs (where Clusterio routes all plugin logger output, invisible in
  `docker logs`) are now mirrored to container stdout with a `[cluster-log]`
  prefix (`CLUSTERIO_LOG_TO_STDOUT`, default true; daily rollover handled).
  CI asserts the payoff.
- **Honest readiness** — controller healthcheck now also requires the
  entrypoint's steady-state marker (healthy = seeded, kills the double
  `up -d`); host healthcheck now requires the boot-race guard's connected
  marker when the tokens volume is present (healthy = connected; degrades to
  process-only standalone); the seeder's `instance start` is a retrying,
  loud-on-failure loop instead of a swallowed one-shot.
- Controller: **static-cache patch absorbed** — `/static`'s `immutable, 1y`
  headers pinned stale web-UI chunks on returning browsers; the controller now
  flips them to revalidation at startup (opt out with
  `CONTROLLER_STATIC_CACHE_MODE=immutable`; graceful no-op if core fixes it
  upstream). Deletes a production consumer's boot-time monkeypatch.
- Export-data hardening: `scripts/regenerate-export-data.sh` (the documented
  post-version-bump step, with retries); host startup WARNING when
  `SKIP_CLIENT=true` on the `EXPORT_HOST`-designated host (blank-icon
  contradiction made visible at the source).
- Plugin docs: `.npmrc legacy-peer-deps` requirement + the two proven
  workstation build patterns; clarified the per-boot `@clusterio` strip.
- **Multi-cluster support**: host-side port publishings (`HOST1_PORTS`,
  `HOST2_PORTS`) and the external client volume name (`FACTORIO_CLIENT_VOLUME`)
  are now `.env`-parametrized; new `docs/multi-cluster.md` documents the four
  collision surfaces. `auto_pause` foot-gun surfaced: docs + example fixed
  (`false`), seeder logs an INFO when unset. README troubleshooting adds the
  frozen-plugins entry and the `DEFAULT_MOD_PACK` live-reassign path.
- CI: **factorio-* PRs now build the custom target** from the fork branch
  matching the PR base — the npm release lags the fork's Factorio-version
  support (empirically: alpha.26 rejects 2.1-format mod `info.json` and lacks
  the `recycler` builtin), so release-target PR runs failed mod seeding on
  content the merge would actually ship. PR validation is now faithful.
- CI: **pre-merge validation for release-branch PRs** — `pull_request` now also
  triggers on PRs into `factorio-*` branches (build + full test suite, no image
  push). The `'*'` push filter's no-slash behavior is now documented as
  intentional in CONTRIBUTING. Issue templates added (`.github/ISSUE_TEMPLATE`)
  codifying the Problem/Evidence/Acceptance format.
- Controller entrypoint: DLC-mod enabling is now **non-fatal but loud** — a
  core without one of the builtins (e.g. `recycler` on pre-alpha.26) previously
  crash-looped the whole controller under `set -e`; now it logs a WARNING and
  the cluster comes up (pack fixable via `mod-pack edit`).
- Host entrypoint: **boot-race guard** — once the controller reports the host
  connected, any instance that auto-started *before* the handshake
  (`startedAtMs` < handshake time) is restarted once so its plugins register.
  Mechanizes the manual stop/start protocol; surgical no-op on healthy boots;
  skips quietly on standalone hosts without the shared tokens volume. CI now
  asserts the guard completes on both hosts after a full-stack restart.
  Upstream fix (loud failure in Clusterio core) tracked separately.
- CI: **changelog gate** (this file) — image-affecting pushes without a change
  notice now fail the build; top entry is published to every run summary.
- Consumer-first compose: `docker compose up -d` now **pulls prebuilt GHCR
  images** (`CLUSTERIO_IMAGE_TAG`, default `factorio-2.1.8`); source builds
  moved to the `docker-compose.dev.yml` overlay, `CLUSTERIO_TARGET` default
  flipped custom → release. (#13)
- Dual-axis immutable tag published on every push build:
  `<branch>-clusterio-<version>` (e.g. `factorio-2.1.8-clusterio-2.0.0-alpha.26`);
  `io.clusterio.version` OCI label; `/clusterio/BUILD_INFO` provenance file in
  both images. (#13)
- Entrypoint: `recycler` added to the Space Age DLC enable list — space-age +
  quality hard-depend on it in Factorio 2.1.x. (#13)
- README: consume-don't-build callout (incl. agents/automation directive),
  tag/provenance docs, external-plugin install contract, boot-race +
  require-cache operational notes; CI-verified Clusterio version badge. (#13)

## 2026-06-22

- Bumped bundled Clusterio to **2.0.0-alpha.26** (all `@clusterio/*` packages,
  release target).

## 2026-06 (earlier)

- Target **Factorio 2.1.8**; CI asserts the default mod pack is "Space Age 2.1".
- Host logs installed Factorio version(s) at startup (#8); plugin-build failure
  WARNING routed to stderr instead of being swallowed (#10).
