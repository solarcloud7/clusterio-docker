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
├── Dockerfile.controller          # Controller image (Node.js + Clusterio controller/ctl + plugins)
├── Dockerfile.host                # Host image (Node.js + Clusterio host/ctl + Factorio headless + plugins)
├── docker-compose.yml             # Default 2-host cluster for local development/testing
├── env/
│   ├── controller.env.example     # Controller environment template
│   └── host.env.example           # Host environment template
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
4. Already configured? (config-host.json exists with valid token)
   ├── YES:
   │   a. Token desync check: compare stored token vs shared volume token
   │   ├── MATCH → Start host immediately (exec)
   │   └── MISMATCH → Delete config, fall through to reconfigure
   └── NO: Continue to step 5
5. Wait for token (from env var or shared volume, up to 300s)
6. Configure host (ID, name, controller URL, token, paths)
7. Start host (exec)
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

### Build Arguments (set at `docker build` / `docker compose build` time)
| Argument | Default | Description |
|----------|---------|-------------|
| `FACTORIO_HEADLESS_TAG` | `stable` | Factorio headless version to download into the host image |

## Volume Mounts

| Mount Point | Purpose | Notes |
|-------------|---------|-------|
| `/clusterio/data` | All persistent data (config, DB, instances) | Docker volume recommended |
| `/clusterio/tokens` | Shared token exchange | Controller: rw, Hosts: ro |
| `/clusterio/seed-data` | Seed data for first run | Controller only, read-only |
| `/clusterio/seed-mods` | Mod pre-cache for hosts | Hosts only, read-only |
| `/clusterio/external_plugins` | External plugin directories | **Must be read-write** (npm install runs) |

**Critical**: External plugins mount must NOT be `:ro` — the entrypoint runs `npm install` inside each plugin directory.

## Development Workflow

### Quick Start
```bash
cp env/controller.env.example env/controller.env
cp env/host.env.example env/host.env
# Edit controller.env: set INIT_CLUSTERIO_ADMIN=your_username
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
docker compose down -v   # Remove containers AND volumes
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
