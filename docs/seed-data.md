# Seed Data

Pre-populate your Clusterio cluster with instances and saves on first run using the seed-data folder convention.

## Directory Structure

```
seed-data/
├── controller/
│   └── config.json                    # Optional: controller config overrides
└── hosts/
    ├── clusterio-host-1/              # Must match hostname in docker-compose
    │   ├── Instance1/
    │   │   └── world.zip              # Save file to upload
    │   └── Instance2/
    │       ├── config.json            # Optional: instance settings
    │       └── save.zip
    └── clusterio-host-2/              # Must match hostname in docker-compose
        └── Instance3/
            └── backup.zip
```

## How It Works

On **first run only** (when no `config-controller.json` exists):

1. Controller scans `seed-data/hosts/` for directories
2. Each host folder **must match** a hostname from docker-compose (e.g., `clusterio-host-1`)
3. Instance folders under each host are created and automatically assigned to that host
4. Any `.zip` files are uploaded as saves to that instance

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

Create a `config.json` in your instance folder for additional settings:

```json
{
  "auto_start": false
}
```

| Option | Type | Description |
|--------|------|-------------|
| `auto_start` | boolean | *(future)* Start instance after creation |

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
