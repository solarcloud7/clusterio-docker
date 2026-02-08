# Clusterio Docker

Docker images for running [Clusterio](https://github.com/clusterio/clusterio) - a clustered Factorio server manager.

## Table of Contents

- [Images](#images)
- [Quick Start](#quick-start)
- [Standalone Usage](#standalone-usage)
- [Volume Mounts](#volume-mounts)
- [Environment Variables](#environment-variables)
- [Getting Host Tokens](#getting-host-tokens)
- [Seed Data](#seed-data)
- [Viewing Logs](#viewing-logs)
- [Prometheus Metrics](#prometheus-metrics)
- [Included Plugins](#included-plugins)
- [External Plugins](#external-plugins)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Building Locally](#building-locally)
- [License](#license)

---

## Images

Pre-built images are published to the GitHub Container Registry:

| Image | Description |
|-------|-------------|
| `ghcr.io/solarcloud7/clusterio-controller` | Web UI, API, and cluster coordination |
| `ghcr.io/solarcloud7/clusterio-host` | Factorio server host (runs game instances) |

```bash
docker pull ghcr.io/solarcloud7/clusterio-controller:latest
docker pull ghcr.io/solarcloud7/clusterio-host:latest
```

## Quick Start

### Using Docker Compose (Recommended)

1. Clone this repository:
   ```bash
   git clone https://github.com/solarcloud7/clusterio-docker.git
   cd clusterio-docker
   ```

2. Create environment files:
   ```bash
   cp env/controller.env.example env/controller.env
   cp env/host.env.example env/host.env
   ```

3. Edit `env/controller.env` and set your admin username:
   ```env
   INIT_CLUSTERIO_ADMIN=your_username
   ```

4. Start the cluster:
   ```bash
   docker compose up -d
   ```

5. Access the web UI at http://localhost:8080

---

## Standalone Usage

### Controller

```bash
docker run -d \
  --name clusterio-controller \
  -p 8080:8080 \
  -v controller-data:/clusterio/data \
  -v shared-tokens:/clusterio/tokens \
  -e INIT_CLUSTERIO_ADMIN=your_username \
  ghcr.io/solarcloud7/clusterio-controller
```

### Host

```bash
docker run -d \
  --name clusterio-host \
  -p 34100-34199:34100-34199/udp \
  -v host-data:/clusterio/data \
  -v shared-tokens:/clusterio/tokens:ro \
  -e CLUSTERIO_HOST_TOKEN=your_host_token \
  -e CONTROLLER_URL=http://your-controller:8080/ \
  ghcr.io/solarcloud7/clusterio-host
```

---

## Volume Mounts

Each container uses a single data volume for all persistent storage:

| Container | Volume Mount | Contents |
|-----------|--------------|----------|
| Controller | `/clusterio/data` | Config, database, mods, logs |
| Controller | `/clusterio/tokens` | Generated host tokens (shared) |
| Controller | `/clusterio/seed-data` | Seed data for first run (read-only bind mount) |
| Host | `/clusterio/data` | Config, instances, mods, logs |
| Host | `/clusterio/tokens` | Token from controller (read-only) |
| Host | `/clusterio/seed-mods` | Mod cache from seed data (read-only bind mount) |

### Data Volume Structure

```
# Controller /clusterio/data/
├── config-controller.json    # Controller configuration
├── database/                 # Users, hosts, instances, roles
└── (mods/, logs/ created as needed)

# Host /clusterio/data/
├── config-host.json          # Host configuration
├── instances/                # Game saves, instance configs
└── (mods/, logs/ created as needed)
```

> **Note**: Volumes are recommended but not required. Without mounts, data is lost when the container is removed.

### Bind Mount (Direct Host Access)

For direct access to files from your host machine:

```bash
# Controller
docker run -d -p 8080:8080 \
  -v ./data/controller:/clusterio/data \
  -v ./tokens:/clusterio/tokens \
  -e INIT_CLUSTERIO_ADMIN=admin \
  ghcr.io/solarcloud7/clusterio-controller

# Host  
docker run -d -p 34100-34199:34100-34199/udp \
  -v ./data/host:/clusterio/data \
  -v ./tokens:/clusterio/tokens:ro \
  -e CLUSTERIO_HOST_TOKEN=your_token \
  ghcr.io/solarcloud7/clusterio-host
```

---

## Environment Variables

### Controller

| Variable | Default | Description |
|----------|---------|-------------|
| `INIT_CLUSTERIO_ADMIN` | *(required)* | Admin username for first run |
| `CONTROLLER_HTTP_PORT` | `8080` | Web UI / API port |
| `CONTROLLER_PUBLIC_ADDRESS` | *(unset)* | Public URL for external access (standalone usage) |
| `HOST_COUNT` | `0` (standalone) / `2` (compose) | Number of host tokens to generate |

### Host

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTERIO_HOST_TOKEN` | *(auto from shared volume)* | Host authentication token |
| `CONTROLLER_URL` | `http://clusterio-controller:8080/` | Controller URL |
| `HOST_NAME` | Container hostname | Host identifier (must match token file name) |

---

## Getting Host Tokens

### Option 1: Shared Volume (Docker Compose)

When using docker-compose, the controller automatically generates tokens based on `HOST_COUNT` and saves them to a shared volume. Hosts read tokens from this volume automatically.

**Important:** For auto-token loading to work, hosts must be named `clusterio-host-N` where N matches the host ID:

| Host Name | Token File | Host ID |
|-----------|------------|---------|
| `clusterio-host-1` | `clusterio-host-1.token` | 1 |
| `clusterio-host-2` | `clusterio-host-2.token` | 2 |
| `clusterio-host-3` | `clusterio-host-3.token` | 3 |

The host extracts its numeric ID from its name (e.g., `clusterio-host-1` → ID `1`).

### Option 2: Manual Token (Standalone)

For standalone containers or custom host names:

1. Start the controller
2. Generate a token via CLI:
   ```bash
   docker exec clusterio-controller npx clusteriocontroller bootstrap generate-host-token 1
   ```
3. Pass the token to host via `CLUSTERIO_HOST_TOKEN` environment variable:
   ```bash
   docker run -d \
     -v host-data:/clusterio/data \
     -e CLUSTERIO_HOST_TOKEN=eyJhbGci... \
     -e CONTROLLER_URL=http://your-controller:8080/ \
     ghcr.io/solarcloud7/clusterio-host
   ```

### Option 3: Web UI

1. Log into the controller web UI
2. Navigate to Hosts → Create Host Token
3. Use the generated token

---

## Seed Data

Pre-populate your cluster with users, roles, mods, instances, and saves on first run using the `seed-data/` folder convention:

```
seed-data/
├── controller/
│   └── database/          # users.json, roles.json (copied before controller starts)
├── mods/                  # Factorio mod .zip files (uploaded to controller)
└── hosts/
    └── clusterio-host-1/  # Must match docker-compose hostname
        └── MyInstance/
            └── world.zip  # Save file to upload
```

On first run (clean volumes), the controller automatically:
1. Seeds database files (users, roles)
2. Uploads mods to the controller
3. Creates instances, assigns them to hosts, uploads saves
4. Starts instances automatically (override with `config.json`)

Hosts pre-cache mods locally from the seed-data mount on every startup for faster instance starts.

> See [docs/seed-data.md](docs/seed-data.md) for full documentation including examples, config options, and troubleshooting.

---

## Viewing Logs

### Dozzle
https://github.com/amir20/dozzle

### Docker Desktop 

Docker Desktop provides an excellent built-in log viewer with a merged timeline from all containers:

![Docker Desktop Logs](docs/images/docker-desktop-logs.png)


### Command Line

```bash
# View logs from a specific container
docker logs clusterio-controller

# Follow logs in real-time
docker logs -f clusterio-host-1

# Show last 100 lines
docker logs --tail 100 clusterio-host-2

# Show logs with timestamps
docker logs -t clusterio-controller
```

---

## Prometheus Metrics

The docker-compose setup includes an optional (commented-out) Prometheus container for collecting metrics from the `statistics_exporter` plugin. Uncomment the `prometheus` service in `docker-compose.yml` to enable it.

### Access

- **Prometheus UI**: http://localhost:9090
- **Controller metrics**: http://localhost:8080/metrics

### Configuration

Edit [scripts/prometheus.yml](scripts/prometheus.yml) to customize scrape targets:

```yaml
scrape_configs:
  - job_name: 'clusterio-controller'
    static_configs:
      - targets: ['clusterio-controller:8080']
    metrics_path: /metrics

  - job_name: 'clusterio-hosts'
    static_configs:
      - targets:
          - 'clusterio-host-1:8080'
          - 'clusterio-host-2:8080'
    metrics_path: /metrics
```

### Available Metrics

The `statistics_exporter` plugin exposes metrics including:

- `clusterio_controller_connected_hosts` - Number of connected hosts
- `clusterio_instance_*` - Per-instance game statistics
- `clusterio_player_*` - Player activity metrics

After changes, restart Prometheus:
```bash
docker compose restart prometheus
```

---

## Included Plugins

Both images include these official plugins:

- `global_chat` - Cross-server chat
- `inventory_sync` - Sync player inventories
- `player_auth` - Player authentication
- `research_sync` - Sync research progress
- `statistics_exporter` - Prometheus metrics
- `subspace_storage` - Shared item storage

---

## External Plugins

To use external Clusterio plugins, mount a plugins directory into the containers:

1. Uncomment the external plugins volume in `docker-compose.yml` for the controller and each host
2. Place plugin directories (each containing a `package.json`) in the `plugins/` folder
3. Plugins are automatically installed on container startup

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │        Prometheus           │
                    │  - Metrics collection       │
                    │  - Query UI (port 9090)     │
                    └──────────────┬──────────────┘
                                   │ scrapes
                                   ▼ /metrics
┌─────────────────────────────────────────────────────────┐
│                    Controller                           │
│  - Web UI (port 8080)                                   │
│  - REST API                                             │
│  - Cluster coordination                                 │
│  - User/role management                                 │
└──────────────────────┬──────────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
┌───────────┐  ┌───────────┐  ┌───────────┐
│  Host 1   │  │  Host 2   │  │  Host N   │
│           │  │           │  │           │
│ Instance  │  │ Instance  │  │ Instance  │
│ Instance  │  │ Instance  │  │ Instance  │
└───────────┘  └───────────┘  └───────────┘
```

---

## Troubleshooting

### Permission Denied Errors

The containers use `gosu` to handle volume permissions automatically. If you still see permission errors:

```bash
# Fix permissions on bind mounts
sudo chown -R 1000:1000 ./data/controller
sudo chown -R 1000:1000 ./data/host
```

### Host Can't Connect to Controller

1. Ensure controller is healthy: `docker compose ps`
2. Check controller logs: `docker logs clusterio-controller`
3. Verify `CONTROLLER_URL` is correct (use Docker network name, not localhost)
4. Check token is valid

### Container Keeps Restarting

Check logs for errors:
```bash
docker logs clusterio-controller
docker logs clusterio-host-1
```

---

## Building Locally

```bash
# Build both images
docker compose build

# Build individually
docker build -f Dockerfile.controller -t clusterio-controller .
docker build -f Dockerfile.host -t clusterio-host .
```

---

## License

MIT License - See [LICENSE](LICENSE) for details.

## Links

- [Clusterio GitHub](https://github.com/clusterio/clusterio)
- [Clusterio Documentation](https://github.com/clusterio/clusterio/blob/master/docs/readme.md)
