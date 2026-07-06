# Discord Bridge

The Discord bridge is an opt-in controller-local HTTP service for a trusted bot. It is designed for private Docker networking, not host exposure.

## Security Model

1. Create a dedicated Docker network attached only to the Clusterio controller and the Discord bot.
2. Do not publish `BRIDGE_PORT` to the host.
3. Bind the bridge to the controller's IP on that dedicated network with `BRIDGE_BIND_HOST`.
4. Set `BRIDGE_ALLOWED_CIDRS` to the dedicated network CIDR or to the bot's static IP/CIDR.
5. Set a strong `BRIDGE_TOKEN`; the controller refuses to start the bridge without it.
6. Leave `BRIDGE_ALLOW_RAW=false` unless you intentionally want raw RCON passthrough. The default command path uses curated templates only.

Inside one Docker network, container-to-container traffic is not NATed, so the bridge sees the real peer container IP. Traffic through a host-published port can arrive as the Docker gateway IP, which is another reason this bridge should not be published.

## Controller Compose Example

Add a private bridge network and give the controller a static address on it:

```yaml
services:
  clusterio-controller:
    environment:
      - BRIDGE_PORT=8100
      - BRIDGE_TOKEN=${BRIDGE_TOKEN:?set BRIDGE_TOKEN}
      - BRIDGE_BIND_HOST=172.31.50.10
      - BRIDGE_ALLOWED_CIDRS=172.31.50.0/24
      - BRIDGE_ALLOW_RAW=false
    networks:
      clusterio-net:
      bridge-net:
        ipv4_address: 172.31.50.10

networks:
  bridge-net:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.31.50.0/24
```

Do not add a `ports:` entry for `8100`.

## Bot Compose Example

Attach the bot to the same private network and point it at the controller's bridge address:

```yaml
services:
  bot:
    environment:
      CLUSTERIO_BRIDGE_URL: http://172.31.50.10:8100
      CLUSTERIO_BRIDGE_TOKEN: ${BRIDGE_TOKEN:?set BRIDGE_TOKEN}
    networks:
      - factorio
      - factorio-shared
      - bridge-net

networks:
  bridge-net:
    external: true
    name: clusterio-docker_bridge-net
```

If the bot compose project creates the network instead, make the Clusterio project reference it as an external network. The important property is membership: controller plus bot only.

## API

All endpoints require `Authorization: Bearer <BRIDGE_TOKEN>`.

- `GET /health` proves the bridge can make a controller round trip.
- `GET /instances` returns live instances.
- `GET /hosts` returns live host connection state.
- `GET /commands` returns curated command templates.
- `POST /commands` accepts `{ "instanceId": 1, "template": "players-online", "params": {} }`.
- `POST /rcon` accepts raw commands only when `BRIDGE_ALLOW_RAW=true`; otherwise it returns `403`.

Curated templates currently include `players-online`, `seed`, `time`, `evolution`, `list-surfaces`, and `surface-export-list-platforms`.

## Failure Behavior

- `BRIDGE_PORT` unset: no bridge process starts.
- `BRIDGE_PORT` set without `BRIDGE_TOKEN` or `BRIDGE_BIND_HOST`: controller exits loudly before becoming healthy.
- stopped, starting, unknown, or unassigned instances return clean 4xx JSON instead of hanging.
- oversized request bodies and overlarge commands are rejected.
- long RCON output is truncated with an explicit bridge marker.