# Consumer Integration Guide

How to use clusterio-docker images in a downstream project.

## Image Tags

| Tag | Source | Use Case |
|-----|--------|----------|
| `latest` / `main` | npm registry (`@clusterio/*`) | Stable, published Clusterio |
| `ExtendedExportData` | Fork branch `solarcloud7/clusterio:ExtendedExportData` | Custom builds with export-data enhancements |

```yaml
# Example: use the custom branch images
image: ghcr.io/solarcloud7/clusterio-docker-controller:ExtendedExportData
image: ghcr.io/solarcloud7/clusterio-docker-host:ExtendedExportData
```

> **Note:** Image names include `-docker-` (derived from the repo name `clusterio-docker`).

## Compose Setup

```yaml
services:
  clusterio-controller:
    image: ghcr.io/solarcloud7/clusterio-docker-controller:ExtendedExportData
    hostname: clusterio-controller          # MUST stay as-is (hosts connect to this)
    ports:
      - "8080:8080"
    volumes:
      - controller-data:/clusterio/data
      - shared-tokens:/clusterio/tokens
      - ./seed-data:/clusterio/seed-data:ro
      # External plugins — MUST be read-write (npm install runs inside):
      - ./plugins:/clusterio/external_plugins
    environment:
      - INIT_CLUSTERIO_ADMIN=your_username  # Required on first run
      - HOST_COUNT=1                        # Number of hosts to generate tokens for
      - EXPORT_HOST=1                       # Which host has the game client (0 = skip)
      - DEFAULT_MOD_PACK=Space Age 2.0

  clusterio-host-1:
    image: ghcr.io/solarcloud7/clusterio-docker-host:ExtendedExportData
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
  host-1-data:
  shared-tokens:
  factorio-client:
    external: true    # Survives `docker compose down -v`
```

## Automatic Asset Export (export-data)

Export-data generates item icons, recipe data, and spritesheets for the web UI.

**Requirements:**
1. One host must have the full Factorio game client — set `FACTORIO_USERNAME` + `FACTORIO_TOKEN` on the host for runtime download, or bake it in with `INSTALL_FACTORIO_CLIENT=true` at build time
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

If you hit this on an older image, manually remove `@clusterio` from the plugin's `package-lock.json` or delete `node_modules/@clusterio/` from the plugin directory.

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
