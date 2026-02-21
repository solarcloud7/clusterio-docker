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
    │   │   ├── instance.json           # Native Clusterio instance config (optional)
    │   │   └── world.zip              # Save file to upload
    │   └── Instance2/
    │       └── save.zip
    └── clusterio-host-2/
        └── Instance3/
            ├── instance.json
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

1. On every startup, all `.zip` files in `seed-data/mods/` are uploaded to the **controller** via the API (already-uploaded mods are skipped)
2. Uploaded mods are automatically **added to the default mod pack** (`DEFAULT_MOD_PACK` env var, e.g., "Space Age 2.0"). The `--add-mods` command is idempotent — already-added mods are unchanged
3. **Hosts** pre-cache mods locally from the same seed-data mount on every startup — no network download needed
4. **Instances** automatically get symlinks to the host's cached mods when they start

> **Important:** You only need to place mods in `seed-data/mods/`. Do **not** manually copy mods to hosts or instances — Clusterio handles distribution automatically. Both the controller upload and host-side caching run on every startup, so new mods added to `seed-data/mods/` are picked up without requiring a full volume wipe (`docker compose down -v`).

> **Filename convention:** Mod zips must follow Factorio's naming convention: `modname_version.zip` (e.g., `squeak-through-2_0.1.3.zip`). The name and version are parsed from the filename to add the mod to the mod pack.

You can also manage mod packs manually via the Web UI or CLI:

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
4. If an `instance.json` is present, its configuration is applied (server settings, plugins, etc.)
5. Any `.zip` files are uploaded as saves to that instance
6. Instances are **started automatically** by default (override with `instance.auto_start: false` in `instance.json`)

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
        │   ├── instance.json
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
    │   │   ├── instance.json
    │   │   └── eu-save.zip
    │   └── Server-US/
    │       ├── instance.json
    │       └── us-save.zip
    └── clusterio-host-2/
        └── Server-Asia/
            ├── instance.json
            └── asia-save.zip
```

## Instance Configuration

Place a native Clusterio `instance.json` in your instance folder to configure server settings, plugins, and behavior. This is the same format Clusterio uses internally.

You can export an existing instance's config from the Web UI or copy one from a running container:

```bash
# Export from a running instance
docker exec clusterio-host-1 cat /clusterio/data/instances/MyInstance/instance.json > seed-data/hosts/clusterio-host-1/MyInstance/instance.json
```

### Example instance.json

```json
{
  "instance.auto_start": true,
  "factorio.version": "2.0.73",
  "factorio.game_port": 34198,
  "factorio.settings": {
    "name": "My Server",
    "description": "A Factorio server",
    "visibility": { "public": true, "lan": true },
    "max_players": 100,
    "auto_pause": true
  },
  "global_chat.load_plugin": true,
  "research_sync.load_plugin": false
}
```

### Skipped Fields

The following fields are **automatically skipped** during seeding because they are runtime or environment-specific:

| Field | Reason |
|-------|--------|
| `instance.id` | Auto-assigned by controller on create |
| `instance.name` | Taken from folder name |
| `instance.assigned_host` | Determined by folder structure |
| `factorio.host_assigned_game_port` | Runtime only |
| `factorio.rcon_port` | Auto-generated |
| `factorio.rcon_password` | Auto-generated |
| `factorio.mod_pack_id` | Numeric ID varies across clusters |
| `_warning` | Clusterio metadata |

All other fields (server settings, plugin toggles, factorio version, etc.) are applied via the Clusterio API.

> **Tip:** `instance.auto_start` is read to decide whether to start the instance after seeding, but is **not** set via the API — Clusterio's built-in auto-start handles restarts after the initial seed.

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

- The host is determined by folder structure, not instance.json
- Move instance folder to correct host folder

### Save not uploaded

- Verify file has `.zip` extension
- Check it's a valid Factorio save
- Look for upload errors in controller logs
