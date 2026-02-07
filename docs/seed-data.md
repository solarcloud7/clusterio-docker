# Seed Data

Pre-populate your Clusterio cluster with instances, saves, users, and roles on first run using the seed-data folder convention.

## Directory Structure

```
seed-data/
├── controller/
│   └── database/                      # Database files (copied before controller starts)
│       ├── users.json                 # Pre-create user accounts
│       └── roles.json                 # Custom permission roles
├── mods/                              # Factorio mod .zip files (uploaded to controller)
│   ├── my-mod_1.0.0.zip
│   └── another-mod_2.1.0.zip
└── hosts/
    ├── clusterio-host-1/              # Must match hostname in docker-compose
    │   ├── Instance1/
    │   │   └── world.zip              # Save file to upload
    │   └── Instance2/
    │       └── save.zip
    └── clusterio-host-2/
        └── Instance3/
            └── backup.zip
```

## Seeding Approaches

This uses a **hybrid approach**:

| What | Method | When |
|------|--------|------|
| Users, Roles | Direct database copy | Before controller starts |
| Mods | API upload (`clusterioctl mod upload`) | After controller starts |
| Instances, Saves | API (`clusterioctl`) | After controller starts |

## Database Seeding (Users, Roles)

Place JSON files in `seed-data/controller/database/` to pre-populate the database.

### users.json

```json
[
    {
        "name": "my_factorio_name",
        "roles": [0],
        "is_admin": true,
        "is_banned": false,
        "is_whitelisted": true,
        "instances": [],
        "instance_stats": [],
        "updated_at_ms": 0,
        "is_deleted": false
    }
]
```

### roles.json

```json
[
    {
        "id": 0,
        "name": "Cluster Admin",
        "description": "Full access to everything",
        "permissions": ["core.admin"],
        "updated_at_ms": 0,
        "is_deleted": false
    },
    {
        "id": 1,
        "name": "Player", 
        "description": "Default player role",
        "permissions": [
            "core.control.connect",
            "core.instance.list",
            "core.host.list"
        ],
        "updated_at_ms": 0,
        "is_deleted": false
    }
]
```

> **Note:** Example files are provided with `.example.json` extension. Copy and rename to `.json` to use.

## Mod Seeding

Place Factorio mod `.zip` files in `seed-data/mods/` to upload them to the controller on first run.

```
seed-data/
└── mods/
    ├── my-mod_1.0.0.zip
    └── another-mod_2.1.0.zip
```

**How it works:**

1. On first run, all `.zip` files in `seed-data/mods/` are uploaded to the **controller** via the API
2. **Hosts** pre-cache mods locally from the same seed-data mount on every startup — no network download needed
3. **Instances** automatically get symlinks to the host's cached mods when they start

> **Important:** You only need to place mods in `seed-data/mods/`. Do **not** manually copy mods to hosts or instances — Clusterio handles distribution automatically. The host-side caching is an optimization that avoids redundant controller→host downloads, which is especially useful during plugin development where volumes are frequently wiped.

After mods are uploaded, create a **Mod Pack** via the Web UI or CLI to assign mods to instances:

```bash
# Create a mod pack
docker exec clusterio-controller npx clusterioctl mod-pack create "My Pack" 2.0 --mods my-mod:1.0.0

# List uploaded mods
docker exec clusterio-controller npx clusterioctl mod list
```

## Instance Seeding (Hosts)

On **first run only** (when no `config-controller.json` exists):

1. Controller scans `seed-data/hosts/` for directories
2. Each host folder **must match** a hostname from docker-compose (e.g., `clusterio-host-1`)
3. Instance folders under each host are created and automatically assigned to that host
4. Any `.zip` files are uploaded as saves to that instance
5. Instances are **started automatically** by default (override with `config.json`)

## Host Folder Naming

The folder name **must exactly match** the container hostname:

| Docker Compose Hostname | Seed Data Folder |
|------------------------|------------------|
| `clusterio-host-1` | `seed-data/hosts/clusterio-host-1/` |
| `clusterio-host-2` | `seed-data/hosts/clusterio-host-2/` |
| `my-custom-host-3` | `seed-data/hosts/my-custom-host-3/` |

The host ID is extracted from the folder name (e.g., `clusterio-host-1` → ID `1`).

## Examples

### Single Host Setup

```
seed-data/
└── hosts/
    └── clusterio-host-1/
        ├── Production/
        │   └── world.zip
        └── Testing/
            └── test-save.zip
```

### Multi-Host Setup

```
seed-data/
└── hosts/
    ├── clusterio-host-1/
    │   ├── Server-EU/
    │   │   └── eu-save.zip
    │   └── Server-US/
    │       └── us-save.zip
    └── clusterio-host-2/
        └── Server-Asia/
            └── asia-save.zip
```

## Instance Config Options

Create a `config.json` in your instance folder to override default behavior:

```json
{
  "auto_start": false
}
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `auto_start` | boolean | `true` | Start instance automatically after seeding |

> **Note:** `assigned_host` is no longer needed - the host is determined by the folder structure.

## Usage

1. Create a folder matching your hostname in `seed-data/hosts/`
   ```
   seed-data/hosts/clusterio-host-1/
   ```

2. Create instance folders inside:
   ```
   seed-data/hosts/clusterio-host-1/MyInstance/
   ```

3. Add your `.zip` save files:
   ```
   seed-data/hosts/clusterio-host-1/MyInstance/world.zip
   ```

4. Start fresh (removes existing data):
   ```bash
   docker compose down -v
   docker compose up -d
   ```

5. Check logs to verify seeding:
   ```bash
   docker logs clusterio-controller | grep -i "seed\|instance\|host"
   ```

## Notes

- Seeding only runs on **first startup** (clean volumes)
- Host folder names must match docker-compose hostnames exactly
- Instance names come from folder names - use valid names
- Save files must be valid Factorio `.zip` saves
- The `seed-data/` folder is mounted read-only
- After seeding, manage instances via Web UI or `clusterioctl`

## Troubleshooting

### Instance not created

- Verify host folder name matches docker-compose hostname exactly
- Check instance folder exists under the host folder
- Check controller logs for errors

### Instance on wrong host

- The host is determined by folder structure, not config.json
- Move instance folder to correct host folder

### Save not uploaded

- Verify file has `.zip` extension
- Check it's a valid Factorio save
- Look for upload errors in controller logs
