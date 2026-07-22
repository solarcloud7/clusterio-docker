# Contributing

Thanks for helping improve **clusterio-docker** — pre-built Docker images for
running [Clusterio](https://github.com/clusterio/clusterio) clusters.

## Local development

```bash
cp .env.example .env          # set INIT_CLUSTERIO_ADMIN
docker volume create factorio-client
docker compose up -d          # web UI at http://localhost:8080
```

See [CLAUDE.md](CLAUDE.md) (“Development Workflow”) for the hot-deploy script,
custom-fork builds, and more. VSCode tasks for the common operations live in
`.vscode/tasks.json`.

## Testing

CI (`.github/workflows/docker-build.yml`) builds both images and runs the
integration suite: database/mod/instance seeding, instance start, and an
idempotent-restart check. Reproduce locally with `docker compose up -d` (release
target) or the `Clusterio: …` VSCode tasks.

Please make sure CI is green before requesting a merge.

## Branches & CI targets

**The default branch is `main`, the active line** — built from the `release` (npm) target — see
README → "Branch model". Base PRs on `main`. The `custom`/fork target is retained but **dormant**:
a `factorio-<X.Y>` branch builds `custom` only when a new Factorio version outpaces npm support
(as `factorio-2.1.8` did before Clusterio alpha.27 added 2.1).

- **Pull requests into `main`**, **`main`**, and **tags** build the `release` target
  (npm-published `@clusterio/*` packages, pinned via `CLUSTERIO_VERSION`).
- **Pull requests into `factorio-*` branches** build the `custom` target from the fork branch
  matching the PR's **base** — faithful to what the merge will publish (used when the npm release
  lags a new Factorio version). PR builds never push images.
- **Non-main branch _pushes_** build the `custom` target from the matching branch
  of the `solarcloud7/clusterio` fork (falling back to the fork's default branch).
- **Slash-named branches (`feat/...`, `docs/...`) intentionally get no push CI** — the `'*'`
  filter doesn't cross `/`, which keeps feature branches from publishing image tags. Open a PR
  into the target branch to get pre-merge validation instead.

## Releasing

See [CLAUDE.md](CLAUDE.md) → “Release Process”. In short: bump `CLUSTERIO_VERSION`
in both Dockerfiles, open a PR, and merge once green — the `main` push publishes
the images.

## Pull requests

- Keep changes focused and update docs (README / CLAUDE.md / `docs/`) when
  behavior changes.
- Any change to image-affecting files (`Dockerfile.*`, `scripts/`,
  `docker-compose*.yml`, workflows) must include a `CHANGELOG.md` entry — CI's
  **changelog gate** fails the push build without one, and the top entry is
  published to the build's run summary.
- Don't commit secrets — see [SECURITY.md](SECURITY.md).
