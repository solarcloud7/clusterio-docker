# Container acceptance

Fast regressions:

```sh
bash tests/seed-instances-order.test.sh
bash tests/seed-mod-versions.test.sh
node --test tests/*.test.cjs
```

Build the release selection you intend to test, then run one acceptance command:

```sh
docker build -f Dockerfile.controller --build-arg CLUSTERIO_PLUGINS=none -t acceptance-controller .
docker build -f Dockerfile.host --build-arg CLUSTERIO_PLUGINS=none -t acceptance-host .
node tests/consumer-smoke.mjs acceptance-controller acceptance-host --previous-host ghcr.io/solarcloud7/clusterio-docker-host:2.0.0-alpha.27.r7
```

The previous image must be available locally (pull it first when needed). CI pins its digest.
Default expected plugins are `none`; pass `--plugins global_chat` for a selected image, or the
explicit comma-separated six names for a full image. Use `--skip-package` for custom
images: their pnpm workspace is not an npm installation target. The packaged-consumer case
runs on release selections separately. Ordinary CLI verification accepts an explicit
expected plugin array and checks shared package resolution; without an array it reports
discovery without claiming selection coverage.

Choose a single case with `--case NAME`. Omitting it runs every case:

| Case | Contract |
|---|---|
| lifecycle | Fresh boot, non-root hooks, recreation, persisted configuration/mods/assets/logs, served asset bytes |
| rotation | Explicit token wins over a stale mounted token; omitting the override restores file priority; unrelated configuration survives |
| overrides | Explicit URL/port changes apply; omitted inputs preserve saved values |
| saved-identity | A renamed container does not change saved identity or confuse readiness |
| hook-identity | Final hook-written ID, matching credential and URL drive readiness |
| zero-id | A fresh host named with suffix 01 registers as numeric ID 1 |
| failures | A failed hook prevents server startup |
| upgrade | Previous image's native CLI creates configuration on a fresh volume; candidate preserves settings and stored files |

The all-cases run also invokes `native-host-config.cjs` inside the host image. It checks
real CLI reads/writes, invalid numeric writes that return exit code zero, and unreadable
configuration preservation. Settings are written individually; verification reads once
after the batch. This is not an atomic configuration transaction.

Missing `--previous-host` records upgrade as **unverified** and `coverageComplete: false`.
A passing run covers only its listed cases and build configuration. Tests use no game
world or client download. Configuration upgrade acceptance does not certify database,
save-format or disaster recovery.

Reports and redacted, bounded logs are under `ci-artifacts/cd-smoke-*/`. Reports identify
images, BUILD_INFO, harness hash, individual cases and cleanup. Each run owns labelled
containers, volumes and a network; cleanup failure fails the run. A force-killed harness
may leave labelled resources, so inspect ownership before cleanup. Local images remain
for inspection.

## CI and local custom builds

PR CI tests minimal and selected release images with independent BuildKit cache scopes.
The publication job builds its actual release/custom target, runs acceptance on those
loaded full images, then pushes the same images without rebuilding. Existing seeded
integration continues to cover Factorio instance startup.

For a custom source test, use the existing canonical Clusterio checkout:

```sh
python tools/build-custom-context.py ../clusterio --build
node tests/consumer-smoke.mjs clusterio-custom-controller clusterio-custom-host --plugins global_chat,inventory_sync,player_auth,research_sync,statistics_exporter,subspace_storage --skip-package
```

The helper archives tracked source files and this repository's Docker build inputs;
it creates no checkout and excludes local dependencies and Git metadata. It records
the source revision, tracked modifications and context hash. Adjust the expected plugin
list deliberately when testing a fork with a different supported set.

## Review evidence

Local acceptance on 2026-09-10 (reports use UTC):

| Image under test | Evidence | Result |
|---|---|---|
| Original PR host at `c385326` | `cd-smoke-f768fc27-270` (rotation), `cd-smoke-4bc1a977-7d8` (overrides) | Failed: retained old token and old controller URL |
| Original PR host at `c385326` | `cd-smoke-112e620d-414` (saved identity), `cd-smoke-0c8b53fd-586` (zero-padded ID) | Failed: registered host never reached healthy readiness |
| Revised full release, native alpha.27 | `cd-smoke-709da0bf-2ab` | All eight startup scenarios and native configuration checks passed |
| Revised custom images from canonical source `9e727f9`, native alpha.25 | `cd-smoke-3434376f-94a` | All eight startup scenarios and native configuration checks passed |

Every listed run cleaned up its disposable resources. Assertions read native effective
configuration independently of startup messages. The two final runs include configuration
written by the r7 release on a fresh volume. Reports retain image IDs and actual native
CLI versions: custom BUILD_INFO's declared version alone is not evidence of the source
package version. The release selections in CI also exercise packaged plugin installation.

Local review caught an empty-environment compatibility regression. Its failing regression
now passes, and the final rotation scenarios confirm empty optional overrides fall back
correctly. The first fresh-volume upgrade fixture needed normal runtime directory ownership
before invoking the previous CLI; that harness setup was corrected before the final runs.

The first native invalid-write fixture used malformed port text, but Clusterio accepts
that string at configuration-write time. That was a harness assumption, not proof of
rejection. The corrected fixture uses an invalid numeric host ID, which the pinned CLI
rejects while returning zero; readback detects the rejected write.

Earlier native startup evidence is retained in git history. The fixture has no web bundle
or host implementation, so its two native plugin warnings are expected.
