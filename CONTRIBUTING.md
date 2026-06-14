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

- **Pull requests, `main`, and tags** build the `release` target (npm-published
  `@clusterio/*` packages, pinned via `CLUSTERIO_VERSION`).
- **Non-main branch _pushes_** build the `custom` target from the matching branch
  of the `solarcloud7/clusterio` fork (falling back to the fork's default branch).

## Releasing

See [CLAUDE.md](CLAUDE.md) → “Release Process”. In short: bump `CLUSTERIO_VERSION`
in both Dockerfiles, open a PR, and merge once green — the `main` push publishes
the images.

## Pull requests

- Keep changes focused and update docs (README / CLAUDE.md / `docs/`) when
  behavior changes.
- Don't commit secrets — see [SECURITY.md](SECURITY.md).
