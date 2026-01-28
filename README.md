# clusterio-docker

Ready-to-run Docker infrastructure for [Clusterio](https://github.com/clusterio/clusterio) - a clustered Factorio server manager.

This repository provides a complete, production-ready Clusterio setup for Factorio 2.0, including:
- 1 Controller (web UI, cluster management)
- 2 Hosts (each running a Factorio instance)
- All official DLC (Space Age, Quality, Elevated Rails)
- All 6 official Clusterio plugins pre-installed
- Easy plugin and mod support

---

## 🚀 Quick Start (First-Time Setup)

### 1. Clone this repository
```bash
git clone https://github.com/solarcloud7/clusterio-docker.git
cd clusterio-docker
```

### 2. Configure environment
```bash
cp .env.template .env
# Edit .env with your settings (admin username, RCON password, etc)
```
- **You must set at least:**
  - `FACTORIO_ADMINS` (comma-separated usernames)
  - `RCON_PASSWORD` (for remote console access)
- Credentials for the mod portal are only needed if you want to download mods automatically.

### 3. Start the cluster
- **To use pre-built images (recommended for most users):**
  ```bash
  docker compose up -d
  ```
- **To build everything locally (for development or custom changes):**
  ```bash
  docker compose up -d --build
  ```

### 4. Access the Clusterio Web UI
- Open: [http://localhost:8080](http://localhost:8080)
- The admin token will be printed in the logs after first startup (see `data/controller/config-control.json`)

### 5. Connect to your servers in Factorio
- **Game Server 1:** `localhost:34197` (UDP)
- **Game Server 2:** `localhost:34198` (UDP)

---

## Features
- **Official plugins pre-installed:** global_chat, inventory_sync, player_auth, research_sync, statistics_exporter, subspace_storage
- **Easy plugin support:** Drop custom plugins in `plugins/` and restart
- **Easy mod/save support:** Drop `.zip` files in `seed-data/mods/` or `seed-data/saves/`
- **No manual patching required**

## VS Code Helper Tasks

This repository includes several VS Code tasks and PowerShell scripts to make cluster management and development easier:

- **Full Clean Deploy:**
  - `.\tools\deploy-cluster.ps1 -CleanData` — Wipes all data and redeploys the cluster from scratch.
- **Force Rebuild:**
  - `.\tools\deploy-cluster.ps1 -ForceBaseBuild` — Forces a rebuild of the base image before starting the cluster.
- **Show Cluster Status:**
  - `.\tools\show-cluster-status.ps1` — Prints the status of all containers, ports, and key config info.
- **Get Admin Token:**
  - `.\tools\get-admin-token.ps1` — Prints the current Clusterio admin token for web UI login.

You can run these scripts from the VS Code terminal, or use the built-in VS Code task runner (Ctrl+Shift+P → "Tasks: Run Task") for a menu-driven experience.

**Tip:**
- These scripts are especially useful for development, debugging, and resetting your cluster quickly.
- You can customize or add your own helper scripts in the `tools/` directory.
