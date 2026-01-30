# Clusterio Docker

Docker images for running [Clusterio](https://github.com/clusterio/clusterio) - a clustered Factorio server manager.

## Images

| Image | Description |
|-------|-------------|
| `clusterio-controller` | Web UI, API, and cluster coordination |
| `clusterio-host` | Factorio server host (runs game instances) |

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
  -v clusterio-controller-data:/clusterio \
  -e INIT_CLUSTERIO_ADMIN=your_username \
  solarcloud7/clusterio-controller
```

### Host

```bash
docker run -d \
  --name clusterio-host \
  -p 34100-34199:34100-34199/udp \
  -v clusterio-host-data:/clusterio \
  -e CLUSTERIO_HOST_TOKEN=your_host_token \
  -e CONTROLLER_URL=http://your-controller:8080/ \
  solarcloud7/clusterio-host
```

---

## Volume Mounts

### Controller Volumes

| Path | Purpose | Persist? |
|------|---------|----------|
| `/clusterio/database` | Users, hosts, instances, roles | Recommended |
| `/clusterio/mods` | Shared mod storage | Recommended |
| `/clusterio/logs` | Controller logs | Optional |
| `/clusterio/tokens` | Generated host tokens | Recommended |

### Host Volumes

| Path | Purpose | Persist? |
|------|---------|----------|
| `/clusterio/instances` | Game saves, instance configs | Recommended |
| `/clusterio/logs` | Host logs | Optional |
| `/clusterio/tokens` | Shared token volume (read-only) | Recommended |

> **Note**: No volumes are strictly required. Containers work without mounts, but all data is lost when the container is removed.

### Simple Volume Mount

Mount everything to a single volume:

```bash
# Controller
docker run -d -p 8080:8080 \
  -v clusterio-controller:/clusterio \
  -e INIT_CLUSTERIO_ADMIN=admin \
  solarcloud7/clusterio-controller

# Host
docker run -d -p 34100-34199:34100-34199/udp \
  -v clusterio-host:/clusterio \
  -e CLUSTERIO_HOST_TOKEN=your_token \
  solarcloud7/clusterio-host
```

### Bind Mount (Direct Host Access)

```bash
# Controller
docker run -d -p 8080:8080 \
  -v ./data/controller:/clusterio \
  -e INIT_CLUSTERIO_ADMIN=admin \
  solarcloud7/clusterio-controller

# Host  
docker run -d -p 34100-34199:34100-34199/udp \
  -v ./data/host:/clusterio \
  -e CLUSTERIO_HOST_TOKEN=your_token \
  solarcloud7/clusterio-host
```

---

## Environment Variables

### Controller

| Variable | Default | Description |
|----------|---------|-------------|
| `INIT_CLUSTERIO_ADMIN` | *(required)* | Admin username for first run |
| `CONTROLLER_HTTP_PORT` | `8080` | Web UI / API port |
| `CONTROLLER_PUBLIC_ADDRESS` | `http://localhost:8080/` | Public URL for web UI |

### Host

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTERIO_HOST_TOKEN` | *(auto from shared volume)* | Host authentication token |
| `CONTROLLER_URL` | `http://clusterio-controller:8080/` | Controller URL |
| `HOST_NAME` | Container hostname | Host identifier (must match token file name) |
| `HOST_COUNT` | `0` (standalone) / `2` (compose) | Number of host tokens to auto-generate |

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
     -e CLUSTERIO_HOST_TOKEN=eyJhbGci... \
     -e CONTROLLER_URL=http://your-controller:8080/ \
     solarcloud7/clusterio-host
   ```

### Option 3: Web UI

1. Log into the controller web UI
2. Navigate to Hosts → Create Host Token
3. Use the generated token

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

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Controller                           │
│  - Web UI (port 8080)                                   │
│  - REST API                                             │
│  - Cluster coordination                                 │
│  - User/role management                                 │
└─────────────────────┬───────────────────────────────────┘
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
