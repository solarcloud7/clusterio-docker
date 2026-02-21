# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the clusterio-docker project.

## Project Overview

**clusterio-docker** provides pre-built Docker images for running [Clusterio](https://github.com/clusterio/clusterio) clusters — a clustered Factorio server manager. The project publishes two container images to GHCR:

| Image | Purpose |
|-------|---------|
| `ghcr.io/solarcloud7/clusterio-docker-controller` | Web UI, API, cluster coordination |
| `ghcr.io/solarcloud7/clusterio-docker-host` | Factorio headless server host (runs game instances) |

**Note**: GHCR image names include `-docker-` because the CI derives them from the repository name (`clusterio-docker`).

## Repository Structure

```
clusterio-docker/
├── .env.example                   # Environment template (all settings in one file)
├── Dockerfile.controller          # Controller image (Node.js + Clusterio controller/ctl + plugins)
├── Dockerfile.host                # Host image (Node.js + Clusterio host/ctl + Factorio headless + plugins)
├── docker-compose.yml             # Default 2-host cluster for local development/testing
├── scripts/
│   ├── controller-entrypoint.sh   # Controller startup: first-run detection, bootstrap, seeding
│   ├── host-entrypoint.sh         # Host startup: token loading, config, desync detection
│   ├── seed-instances.sh          # Instance creation, assignment, save upload, auto-start
│   ├── seed-mods.sh               # Mod upload to controller
│   ├── install-plugins.sh         # External plugin npm install
│   ├── suppress-dev-warning.js    # Patches Clusterio alpha dev warning
│   └── prometheus.yml             # Optional Prometheus scrape config
├── seed-data/                     # Example seed data (used by CI tests)
│   ├── controller/database/       # users.json, roles.json
│   ├── hosts/                     # Instance folders per host
│   ├── mods/                      # Factorio mod .zip files
│   └── external_plugins/          # External Clusterio plugins
├── tools/
│   └── get-admin-token.ps1        # Retrieve admin token from running controller
├── docs/
│   └── seed-data.md               # Comprehensive seed data documentation
└── .github/workflows/
    └── docker-build.yml           # CI: build, push to GHCR, integration tests
```

## Architecture

### Container Startup Flow

#### Controller (`controller-entrypoint.sh`)

```
1. Create data dirs, fix permissions
2. Install external plugins (npm install if mounted)
3. FIRST_RUN check: does config-controller.json exist on the data volume?
   ├── YES → Skip to step 4
   └── NO (first run):
       a. Copy seed database files (users.json, roles.json)
       b. Configure controller (port, public address, factorio credentials)
       c. Bootstrap admin user (idempotent — checks if already in DB)
       d. Generate config-control.json (API token) → shared tokens volume
       e. Generate host tokens → shared tokens volume
4. Start controller in background, wait for healthcheck
5. SEED check: FIRST_RUN=true OR .seed-complete marker missing?
   ├── NO → Skip to step 6
   └── YES:
       a. Set default mod pack
       b. seed-mods.sh: upload .zip mods to controller
       c. seed-instances.sh: create instances, assign to hosts, upload saves, start
       d. Write .seed-complete marker to data volume
6. Wait on controller process (keep container alive)
```

#### Host (`host-entrypoint.sh`)

```
1. Create data dirs, fix permissions
2. Install external plugins (npm install if mounted)
3. Pre-cache seed mods (copy from seed-mods mount → host mods dir)
4. Runtime client download (if FACTORIO_USERNAME + FACTORIO_TOKEN set, no client yet, SKIP_CLIENT!=true)
   └── Download once → stored in external volume (/opt/factorio-client), persists across restarts
5. Select Factorio directory: volume client → image client → headless
6. Already configured? (config-host.json exists with valid token)
   ├── YES:
   │   a. Token desync check: compare stored token vs shared volume token
   │   ├── MATCH → Start host immediately (exec)
   │   └── MISMATCH → Delete config, fall through to reconfigure
   └── NO: Continue to step 7
7. Wait for token (from env var or shared volume, up to 300s)
8. Configure host (ID, name, controller URL, token, paths)
9. Start host (exec)
```

### Seeding Flow (`seed-instances.sh`)

```
1. Wait for all expected hosts to connect (up to 30 attempts × 2s)
2. Scan seed-data/hosts/<hostname>/ directories
3. For each instance directory:
   a. Idempotency check: skip if instance name already exists
   b. Create instance via clusterioctl
   c. Assign to host by numeric ID (extracted from hostname)
   d. Apply instance.json config (if present), skipping runtime-specific fields
   e. Upload .zip save files
   f. Start instance (unless instance.auto_start=false)
```

## Key Design Decisions

### First-Run Detection
- **Controller**: Checks for `config-controller.json` on the data volume. If absent → `FIRST_RUN=true`.
- **Host**: Checks for `config-host.json` with a valid `controller_token`.
- **Seed completion**: A `.seed-complete` marker file is written after successful API seeding (instances, mods). This allows interrupted first runs to be re-attempted on next startup.

### Idempotency Guarantees
| Operation | Idempotent? | Mechanism |
|-----------|:-----------:|-----------|
| Controller config | ✅ | `FIRST_RUN` flag (file existence check) |
| Admin user creation | ✅ | `grep` check in users.json |
| Token generation | ✅ | Inside `FIRST_RUN` block only |
| Instance creation | ✅ | `instance list` + `grep -wF` before `instance create` |
| Mod upload | ⚠️ Partial | Errors swallowed; controller may reject duplicates |
| API seeding block | ✅ | `.seed-complete` marker file |
| Host configuration | ✅ | Config file existence + token desync detection |

### Token Desync Detection
When the controller volume is wiped but host volumes persist, the controller generates new tokens that won't match what hosts have stored. The host entrypoint compares its stored token against the shared token volume — if they differ, it deletes its config and reconfigures from scratch.

### Hostname Conventions
- Host names **must** follow `clusterio-host-N` pattern for automatic token loading
- The numeric ID is extracted via `grep -oE '[0-9]+$'`
- Token files are named `clusterio-host-N.token` on the shared volume
- Seed data directories under `hosts/` must match hostnames exactly

## Environment Variables

### Controller
| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `INIT_CLUSTERIO_ADMIN` | **Yes** | — | Admin username (first run only) |
| `CONTROLLER_HTTP_PORT` | No | `8080` | Web UI / API port |
| `CONTROLLER_PUBLIC_ADDRESS` | No | — | Public URL for external access |
| `HOST_COUNT` | No | `0` (standalone) / `2` (compose) | Host token count |
| `DEFAULT_MOD_PACK` | No | `Base Game 2.0` | Mod pack name for instances |
| `FACTORIO_USERNAME` | No | — | Factorio.com username |
| `FACTORIO_TOKEN` | No | — | Factorio.com token |

### Host
| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `HOST_NAME` | No | Container hostname | Must match `clusterio-host-N` pattern |
| `CONTROLLER_URL` | No | `http://clusterio-controller:8080/` | Controller address |
| `CLUSTERIO_HOST_TOKEN` | No | Auto from shared volume | Manual token override |
| `FACTORIO_USERNAME` | No | — | Factorio.com username — triggers runtime game client download on first startup |
| `FACTORIO_TOKEN` | No | — | Factorio.com token (from factorio.com/profile) |
| `FACTORIO_CLIENT_BUILD` | No | `expansion` | Runtime client variant: `expansion` (Space Age) or `alpha` (base game) |
| `FACTORIO_CLIENT_TAG` | No | `stable` | Factorio client version tag for runtime download |
| `SKIP_CLIENT` | No | `false` | Set to `true` to force headless even when game client is available |

### Build Arguments (set at `docker build` / `docker compose build` time)
| Argument | Default | Description |
|----------|---------|-------------|
| `FACTORIO_HEADLESS_TAG` | `stable` | Factorio headless version to download into the host image |
| `FACTORIO_HEADLESS_SHA256` | — | SHA256 checksum for headless archive (skips verification if empty) |
| `INSTALL_FACTORIO_CLIENT` | `false` | Install full game client alongside headless for graphical asset export |
| `FACTORIO_CLIENT_BUILD` | `expansion` | Client variant: `alpha` (base game) or `expansion` (Space Age) |
| `FACTORIO_CLIENT_TAG` | `stable` | Factorio client version tag (same format as headless) |
| `FACTORIO_CLIENT_USERNAME` | — | Factorio.com username (required when `INSTALL_FACTORIO_CLIENT=true`) |
| `FACTORIO_CLIENT_TOKEN` | — | Factorio.com token (required when `INSTALL_FACTORIO_CLIENT=true`) |
| `FACTORIO_CLIENT_SHA256` | — | SHA256 checksum for game client archive (skips verification if empty) |
| `CURL_RETRIES` | `8` | Number of curl retry attempts for Factorio downloads |

## Volume Mounts

| Mount Point | Purpose | Notes |
|-------------|---------|-------|
| `/clusterio/data` | All persistent data (config, DB, instances) | Docker volume recommended |
| `/clusterio/tokens` | Shared token exchange | Controller: rw, Hosts: ro |
| `/clusterio/seed-data` | Seed data for first run | Controller only, read-only |
| `/clusterio/seed-mods` | Mod pre-cache for hosts | Hosts only, read-only |
| `/opt/factorio-client` | Runtime-downloaded game client | `external: true` — survives `down -v` |
| `/clusterio/external_plugins` | External plugin directories | **Must be read-write** (npm install runs) |

**Critical**: External plugins mount must NOT be `:ro` — the entrypoint runs `npm install` inside each plugin directory.

## Development Workflow

### Quick Start
```bash
cp .env.example .env
# Edit .env: set INIT_CLUSTERIO_ADMIN=your_username
docker volume create factorio-client
docker compose up -d
# Access Web UI at http://localhost:8080
```

### Building Locally
```bash
docker compose build                                    # Both images
docker build -f Dockerfile.controller -t clusterio-controller .  # Controller only
docker build -f Dockerfile.host -t clusterio-host .              # Host only
```

### Clean Restart
```bash
docker compose down -v   # Remove containers AND volumes (factorio-client persists — it's external)
docker compose up -d     # Fresh start with re-seeding
```

### Restart (Keep Data)
```bash
docker compose restart   # Preserves volumes, no re-seeding
```

### Get Admin Token
```powershell
./tools/get-admin-token.ps1
# Or manually:
docker exec clusterio-controller cat /clusterio/tokens/config-control.json
```

### Viewing Logs
```bash
docker logs clusterio-controller              # Controller logs
docker logs -f clusterio-host-1               # Follow host-1 logs
docker logs clusterio-controller | grep seed  # Check seeding status
```

## CI Pipeline

The GitHub Actions workflow (`.github/workflows/docker-build.yml`):
1. Builds both images with Docker Buildx + GHA cache
2. Pushes to GHCR on non-PR events (tagged: latest, semver, branch)
3. Runs integration tests:
   - Database seeding (admin user)
   - Mod seeding (upload + host pre-cache)
   - Instance seeding (create, save upload, auto-start control)
   - **Idempotent restart** (verifies no duplicate instances after `docker compose restart`)

## Included Clusterio Plugins

Both images install these official plugins:
- `global_chat` — Cross-server chat
- `inventory_sync` — Sync player inventories
- `player_auth` — Player authentication
- `research_sync` — Sync research progress
- `statistics_exporter` — Prometheus metrics
- `subspace_storage` — Shared item storage

## Seed Data Convention

The `seed-data/` directory structure drives first-run provisioning:

```
seed-data/
├── controller/
│   └── database/          # Copied BEFORE controller starts (direct file copy)
│       ├── users.json     # Pre-created user accounts
│       └── roles.json     # Permission roles
├── mods/                  # Uploaded to controller via API AFTER start
│   └── *.zip
├── external_plugins/      # Mounted into containers for npm install
│   └── my_plugin/
│       └── package.json
└── hosts/
    └── clusterio-host-N/  # Folder name MUST match hostname
        └── InstanceName/
            ├── instance.json  # Optional: Clusterio instance config
            └── *.zip          # Save files to upload
```

### instance.json

Native Clusterio `InstanceConfig` format. Runtime-specific fields are auto-skipped:
`instance.id`, `instance.name`, `instance.assigned_host`, `instance.auto_start`, `factorio.host_assigned_game_port`, `factorio.rcon_port`, `factorio.rcon_password`, `factorio.mod_pack_id`

Set `"instance.auto_start": false` to prevent auto-starting after seeding.

## Common Pitfalls

### 1. External Plugins Mount Must Be Read-Write
**Symptom**: Plugin not loaded, npm install errors
**Cause**: Mounting with `:ro` — entrypoint needs to run `npm install`
**Fix**: Remove `:ro` from the external_plugins volume mount

### 2. Host Name Must Match Pattern
**Symptom**: Host can't find token, wrong host ID
**Cause**: Hostname doesn't follow `clusterio-host-N` pattern
**Fix**: Ensure hostname and HOST_NAME env var match `clusterio-host-N`

### 3. Seed Data Directory Names Must Match Hostnames
**Symptom**: Instances not created on expected host
**Cause**: Folder name under `seed-data/hosts/` doesn't match container hostname
**Fix**: Rename folder to match exactly (e.g., `clusterio-host-1`)

### 4. Consumer Projects: Image Names Include `-docker-`
**Symptom**: Image pull fails with `ghcr.io/solarcloud7/clusterio-controller`
**Cause**: GHCR CI derives image name from repo name (`clusterio-docker`)
**Fix**: Use `ghcr.io/solarcloud7/clusterio-docker-controller` and `ghcr.io/solarcloud7/clusterio-docker-host`

### 5. Controller Hostname Must Stay `clusterio-controller`
**Symptom**: Hosts can't connect to controller
**Cause**: Consumer changed the controller's hostname in their compose file
**Fix**: Keep hostname as `clusterio-controller` (container name can be different). Alternatively, set `CONTROLLER_URL` on each host to match the new hostname.

### 6. Game Port Range Auto-Derived from HOST_ID
**Symptom**: Multiple hosts assign the same game port to instances, making some unreachable
**Cause**: All hosts used the same default port range
**Fix**: `host-entrypoint.sh` now auto-derives port range from HOST_ID: host N → `34N00-34N99`. Override with `FACTORIO_PORT_RANGE` env var if needed. Docker-compose port mappings must match (e.g., host 2 maps `34200-34209:34200-34209/udp`).

### 7. DEFAULT_MOD_PACK Defaults to Base Game
**Symptom**: Instances start without DLC mods (Space Age, etc.)
**Cause**: `DEFAULT_MOD_PACK` env var defaults to `"Base Game 2.0"`
**Fix**: Set `DEFAULT_MOD_PACK=Space Age 2.0` in controller env for Space Age support. Requires volume wipe + redeploy (mod pack is set on first run only).

### 8. INSTALL_FACTORIO_CLIENT Credentials Exposed in Image History
**Symptom**: `docker history` reveals Factorio account credentials
**Cause**: Build args (`FACTORIO_CLIENT_USERNAME`, `FACTORIO_CLIENT_TOKEN`) are passed via `--build-arg` which can appear in image layer metadata
**Fix**: Use the **runtime download** instead (set `FACTORIO_USERNAME` + `FACTORIO_TOKEN` as env vars). Credentials are only runtime env vars — they never appear in image layers. The build-time path (`INSTALL_FACTORIO_CLIENT=true`) is only needed for private images; use BuildKit secrets if you must bake the client in.

### 9. Game Client Image Is Much Larger Than Headless
**Symptom**: Host image is ~300-500 MB larger than expected
**Cause**: `INSTALL_FACTORIO_CLIENT=true` downloads the full game client (~450 MB) in addition to the headless server (~100 MB)
**Fix**: Only enable for hosts that need export-data functionality. The headless server is sufficient for running game instances — the client is only needed for Clusterio's graphical asset export.
