# Consumer Integration Guide

How to use clusterio-docker images in a downstream project.

## Image Tags

| Tag | Source | Use Case |
|-----|--------|----------|
| `latest` / `main` | npm registry (`@clusterio/*`), pinned to **`2.0.0-alpha.27`** — **moves** as the docker layer rebuilds | Stable, published Clusterio (newest) |
| `2.0.0-alpha.27` | Same as `latest` — the bundled Clusterio version; **moves** on rebuild | Track a Clusterio version |
| `2.0.0-alpha.27.rN` | An **immutable** revision pin (cut from a git tag); `.rN` bumps for docker-layer fixes on the same Clusterio version | **Production — pin this** |
| `<branch>` | Built from fork branch `solarcloud7/clusterio:<branch>` on a **non-main branch push** (falls back to the fork's default branch, `master`). PRs into `main`, `main`, and tags build the `release` target. | Dormant `custom`/fork path (a `factorio-*` line when npm lags a new Factorio version) |

```yaml
# Example: pull the stable images
image: ghcr.io/solarcloud7/clusterio-docker-controller:latest
image: ghcr.io/solarcloud7/clusterio-docker-host:latest
```

> **Production: pin `:<version>.rN`, not `:latest` or the bare version.** `:latest`,
> `:main`, and `:<version>` are **moving** tags — a rebuild replaces them in place, so an
> unpinned `docker compose up -d`/`pull` can change the running image (and its lineage)
> under you. Only `:<version>.rN` is immutable. This repo's default `docker-compose.yml`
> uses `:latest` for zero-config first runs; override `CLUSTERIO_IMAGE_TAG=<version>.rN` in
> `.env` for anything you depend on.

> **Migrating off old `:1` / `:1.x` / `:1.x.y` tags:** the independent repo-SemVer tag axis
> is **retired** — those tags are frozen at their last build and receive **no** further
> updates. Re-pin to `:<version>.rN` (e.g. `:2.0.0-alpha.27.r1`).

> **Migrating off `:2.0.0-alpha.27-r1` .. `-r4` (hyphen scheme):** these four were published
> before a SemVer-precedence bug in the separator was caught (a hyphen makes `27-r1` sort as
> *newer* than `alpha.28` under SemVer-aware tooling). They're frozen, not deleted — re-pin to
> `:2.0.0-alpha.27.r5` (dot) or later; no further `-rN` (hyphen) tags will be cut.

> **Note:** Image names include `-docker-` (derived from the repo name `clusterio-docker`).

> **Export-data:** The extended per-category export spritesheets (recipes, signals,
> technologies, planets, qualities, entities, static UI icons) are now **mainlined** in
> Clusterio (alpha.23 [#838](https://github.com/clusterio/clusterio/pull/838)), so the
> stable `latest` images already produce them — the old `ExtendedExportData` fork branch
> is superseded. Note the web-UI consumption API changed in alpha.24
> ([#875](https://github.com/clusterio/clusterio/pull/875): `useExportPrototypeMetadata`,
> `FactorioIcon`); downstream UI code that read the old hooks must migrate.

## Compose Setup

```yaml
services:
  clusterio-controller:
    image: ghcr.io/solarcloud7/clusterio-docker-controller:latest
    hostname: clusterio-controller          # MUST stay as-is (hosts connect to this)
    ports:
      - "8080:8080"
    volumes:
      - controller-data:/clusterio/data
      - controller-mods:/clusterio/mods
      - controller-static:/clusterio/static
      - controller-logs:/clusterio/logs
      - shared-tokens:/clusterio/tokens
      - ./seed-data:/clusterio/seed-data:ro
      # External plugins — MUST be read-write (npm install runs inside):
      - ./plugins:/clusterio/external_plugins
    environment:
      - INIT_CLUSTERIO_ADMIN=your_username  # Required on first run
      - HOST_COUNT=1                        # Number of hosts to generate tokens for
      - EXPORT_HOST=1                       # Which host has the game client (0 = skip)
      - DEFAULT_MOD_PACK=Space Age 2.1

  clusterio-host-1:
    image: ghcr.io/solarcloud7/clusterio-docker-host:latest
    hostname: clusterio-host-1              # MUST follow clusterio-host-N pattern
    depends_on:
      clusterio-controller:
        condition: service_healthy
    volumes:
      - host-1-data:/clusterio/data
      - shared-tokens:/clusterio/tokens:ro
      - factorio-client:/opt/factorio-client        # Persists downloaded game client
      - ./seed-data/mods:/clusterio/seed-mods:ro    # Pre-cache mods on host
      - ./plugins:/clusterio/external_plugins       # Must be read-write
    environment:
      - HOST_NAME=clusterio-host-1
      - FACTORIO_USERNAME=${FACTORIO_USERNAME}       # Triggers runtime client download
      - FACTORIO_TOKEN=${FACTORIO_TOKEN}
    ports:
      - "34100-34109:34100-34109/udp"

volumes:
  controller-data:
  controller-mods:
  controller-static:
  controller-logs:
  host-1-data:
  shared-tokens:
  factorio-client:
    external: true    # Survives `docker compose down -v`
```

## Automatic Asset Export (export-data)

Export-data generates item icons, recipe data, and spritesheets for the web UI.

**Requirements:**
1. One host must have the full Factorio game client — set `FACTORIO_USERNAME` + `FACTORIO_TOKEN` on the host for runtime download (recommended), or bake it in with `INSTALL_FACTORIO_CLIENT=true` at build time. Baking requires credentials as **BuildKit secrets** (`--secret id=factorio_username,env=… --secret id=factorio_token,env=…`), not build args, and such images must stay private
2. Set `EXPORT_HOST=N` on the **controller** (N = host ID with game client)
3. At least one instance must be seeded on that host via `seed-data/hosts/clusterio-host-N/`

**How it works:**
- During first-run seeding, before starting the first instance on the export host, the controller runs `clusterioctl instance export-data`
- The host launches Factorio with `--export-data` to generate graphical assets
- Runs once per seeding — subsequent instances skip it
- If export fails (no game client), it logs a warning and continues
- Assets are served at the controller's `/export/` endpoints

**Set `EXPORT_HOST=0` or empty to skip export entirely.**

## External Plugins

Mount your plugin directory into **both** controller and host containers at `/clusterio/external_plugins`. The mount **must be read-write** — the entrypoint runs `npm install` inside each plugin.

```
plugins/
└── my_plugin/
    ├── package.json
    ├── index.js
    └── info.js
```

### Singleton Fix (Custom Builds)

When using `CLUSTERIO_TARGET=custom` (monorepo layout), `npm install` for external plugins can install `@clusterio/lib` and `@clusterio/web_ui` locally into the plugin's `node_modules/`. This creates duplicate singletons — the plugin registers permissions/events in its copy while the controller reads from the monorepo copy, causing fatal crashes like:

```
Error: permission surface_export.ui.view does not exist
```

**The latest images fix this automatically** — `install-plugins.sh` removes `node_modules/@clusterio` after install, forcing Node.js to resolve upward to the shared monorepo copies.

That legacy directory-mount cleanup does not prove version compatibility. For packaged derived images, use compatible peer dependencies and the offline verification below; it detects duplicate resolution without deleting packages.

## Seed Data

```
seed-data/
├── controller/database/           # Copied before controller starts
│   ├── users.json                 # Pre-created user accounts
│   └── roles.json                 # Permission roles
├── mods/                          # Uploaded to controller via API after start
│   └── *.zip
├── external_plugins/              # Mounted into containers
│   └── my_plugin/
└── hosts/
    └── clusterio-host-N/          # Folder MUST match container hostname
        └── InstanceName/
            ├── instance.json      # Optional: Clusterio instance config
            └── *.zip              # Save files to upload
```

- **Instance seeding** runs on first startup (or if `.seed-complete` marker is missing)
- **Mod seeding** runs on every startup — new mods are picked up without volume wipe
- Set `"instance.auto_start": false` in `instance.json` to prevent auto-starting

## Key Constraints

| Constraint | Why |
|-----------|-----|
| Controller hostname must be `clusterio-controller` | Hosts default `CONTROLLER_URL` to `http://clusterio-controller:8080/` |
| Host hostnames must follow `clusterio-host-N` | Token files and host IDs are derived from the name |
| External plugins mount must be **read-write** | `npm install` runs inside each plugin directory |
| `factorio-client` volume should be `external: true` | Preserves ~450 MB download across `docker compose down -v` |
| Game port ranges auto-derive from host ID | Host N → ports `34N00-34N99` |

## Selecting bundled plugins in release builds

Both Dockerfiles accept `CLUSTERIO_PLUGINS`: `all` (the unchanged default), `none`,
or a comma-separated selection of `global_chat,inventory_sync,player_auth,research_sync,statistics_exporter,subspace_storage`.

```sh
docker build -f Dockerfile.controller --build-arg CLUSTERIO_PLUGINS=none -t my-controller .
docker build -f Dockerfile.host --build-arg CLUSTERIO_PLUGINS=none -t my-host .
```

The development Compose overlay forwards the same variable. This applies only to
`CLUSTERIO_TARGET=release`; custom builds use their source tree's plugins. It is a
build input, not a runtime environment switch. Published defaults remain unchanged.

Clusterio discovers installed plugin packages automatically. A smaller plugin-list
does not disable installed bundled plugins. Install your packaged plugins with
normal npm in a derived image and verify the discovered set before starting saves.

## Host configuration precedence

The host reconciles configuration before running pre-start hooks:

| Setting | Fresh volume | Existing volume |
|---|---|---|
| Host ID and name | Derived from HOST_NAME; numeric suffixes are decimal | Saved identity is preserved, even if the container name changes |
| Controller token | Explicit nonempty CLUSTERIO_HOST_TOKEN, then token file | Explicit token, then token file, then saved token |
| Controller URL | Explicit CONTROLLER_URL, otherwise default endpoint | Explicit CONTROLLER_URL replaces it; omission preserves the saved URL |
| Game port range | Explicit FACTORIO_PORT_RANGE, otherwise derived from host ID | Explicit range replaces it; omission preserves the saved range |
| Instances directory | data/instances | Saved path is preserved |
| Factorio directory | Detected client/headless installation | Reconciled to the detected installation |

Empty optional token, URL and port variables are treated as unset, as in earlier images.
Default CONTROLLER_HTTP_PORT
only contributes to a fresh host's fallback URL; use CONTROLLER_URL to change an existing
host's endpoint. Token filenames still follow HOST_NAME. Changing an existing host's
identity is a deliberate operation: update its ID and matching credential together in a hook.

Credential rotation updates the token field without deleting the configuration. Unreadable
configuration stops startup and remains available for diagnosis. Native writes are checked
with one configuration read after all writes, since the pinned CLI can log a rejected value
and return zero. This verification checks accepted values, not connectivity. Writes are
individual native operations, not an atomic transaction.

## Configuring before startup

Mount a directory read-only at `/etc/clusterio/pre-start.d`, or COPY scripts there.
Files ending in `.sh` run through Bash in C-locale filename order as `clusterio`.
They run on every boot after native configuration/bootstrap and before server startup.
Hooks are the final configuration authority. The readiness guard reads the effective ID
and URL afterward. A nonzero hook exit stops startup.

Scripts receive `CLUSTERIO_ROLE` and `CLUSTERIO_CONFIG_PATH`. Make them idempotent.
They have access to the runtime user's configuration and secrets.

Example `10-local-settings.sh`:

```sh
set -eu
/clusterio/node_modules/.bin/clusterio"$CLUSTERIO_ROLE" --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set "$CLUSTERIO_ROLE.allow_remote_updates" false
```

Local `config show FIELD` returns a scalar; strings are raw, not JSON-quoted.
Use remote `clusterioctl host config set ...` on a running host. Local writes are
locked while it runs; some local-only fields require a pre-start hook instead.

## Persistent state and migration

The base Compose file now mounts controller `/clusterio/data`, `/clusterio/mods`,
`/clusterio/static`, `/clusterio/tokens` and `/clusterio/logs`, plus each host's
data and logs. Host mods are a downloadable cache. Preserve the Factorio installation
volume to avoid downloading it again. Include configured plugin storage in backups.

**Existing installations must migrate before recreating containers.** Empty volumes hide
the old container directories; a container's writable layer is not persistent storage.

1. Stop the existing containers without removing them (`docker compose stop`, not `down`).
2. Copy controller mods, static assets and logs, and host logs to a separate backup with
   `docker cp CONTAINER:/clusterio/DIRECTORY ./BACKUP`. Record each directory's file list
   and sizes; keep the original stopped containers until the copy is verified.
3. Populate the corresponding new project-scoped volumes from that backup. Confirm
   ownership allows the image's `clusterio` user to read/write them.
4. Verify the copy before recreating containers with the new Compose file. Check mods,
   served assets and logs after startup; retain backups until acceptance is complete.

The PR does not perform this migration on a running installation.

## Consumer verification

Verify native commands and shared plugin dependency resolution offline:

```sh
docker run --rm --network none --user clusterio --entrypoint node my-controller /scripts/verify-cli.cjs controller '["ci_fixture"]'
```

Supply the exact expected discovered plugin array for your image. Without that argument,
the command reports discovered plugins and checks their shared dependencies, but does not
claim that a particular selection was tested. It supports release packages, derived images,
and custom source layouts. Incompatible peer requirements or duplicate lib/web_ui resolution
fail verification; update compatible dependencies instead of deleting arbitrary packages.

For real startup, recreation and configuration-conflict checks, use the commands and
scenario matrix in [tests/README.md](../tests/README.md). The runner records image identities,
individual results, unverified cases and cleanup. Minimal and selected release combinations
run in CI; publication also accepts its exact full release/custom images before pushing them.
