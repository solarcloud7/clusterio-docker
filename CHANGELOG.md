# Changelog — image change notices

Every push that changes **image-affecting files** (`Dockerfile.*`, `scripts/`,
`docker-compose*.yml`, `.github/workflows/`) MUST add an entry here — CI's
**changelog gate** fails the build otherwise. Newest first.

The top entry is published to each build's run summary, and images carry
`/clusterio/BUILD_INFO` (`gitSha`), so any running container links back to its
change notice: container → sha → this file.

Format: `## YYYY-MM-DD` heading + short bullets. Always state the Clusterio /
Factorio versions when they change.

## 2026-07-05

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
