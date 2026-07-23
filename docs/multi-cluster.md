# Running multiple Clusterio clusters on one machine

Both known production consumers of these images run **two clusters side-by-side on one Docker
host** and each independently maintained a private collision map. This doc makes the rules
first-class. Four global namespaces can collide; parametrize all four per cluster.

## The four collision surfaces

| Surface | Why it collides | Knob |
|---|---|---|
| **Host ports** | Controller UI + game UDP ranges bind host-side | `CONTROLLER_HTTP_PORT`, `HOST1_PORTS`, `HOST2_PORTS` (`.env`) |
| **Container names** | `container_name:` is global to the Docker host | Edit compose service `container_name`/`hostname` per cluster — but keep hostnames matching the `clusterio-host-N` pattern **inside** each compose network (token auto-loading depends on it) |
| **External volumes** | `external: true` names are global — two clusters sharing `factorio-client` will clobber each other's client install (a 2.0 cluster refreshing a 2.1 cluster's client, or vice versa) | `FACTORIO_CLIENT_VOLUME` (`.env`) |
| **Compose project name** | Non-external volumes/networks are prefixed by project (directory) name — two checkouts in same-named dirs share them | `COMPOSE_PROJECT_NAME` or distinct directory names |

## Worked example (a real machine)

| | Cluster A (`surface-export`) | Cluster B (`atlas`) |
|---|---|---|
| Controller UI | `8080` | `8090` |
| Game UDP (host-side) | `34100-34109`, `34200-34209` | `34300` (→ container 34100) |
| Client volume | `factorio-client` | `factorio-client-21` |
| Container prefix | `surface-export-` | `atlas-` |

Cluster B's `.env`:

```bash
CONTROLLER_HTTP_PORT=8090
HOST1_PORTS=34300-34309
HOST2_PORTS=34400-34409
FACTORIO_CLIENT_VOLUME=factorio-client-21
```

> **Direct Connect gotcha**: the game client connects to the **host-side** port
> (`localhost:34300` for cluster B above) — not the container-internal 34100, which may belong
> to the *other* cluster on this machine.

## Rules of engagement

1. Never stop, restart, or exec-mutate containers belonging to another cluster's prefix.
2. Never share an external volume between clusters unless the content is genuinely
   version-agnostic (the Factorio client is **not** — it's a single versioned install).
3. Check what's holding a port before assuming it's yours:
   `docker ps --format '{{.Names}}  {{.Ports}}'`.
