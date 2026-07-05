# Plugin Development against these containers

How to develop a Clusterio plugin (Node + optional save-patched Lua module) using the prebuilt
images — without rebuilding images and without the classic traps. For *running* third-party
plugins, the README's [External Plugins](../README.md#external-plugins) section is enough; this
guide is for writing one.

## Setup

1. Put your plugin in a directory with a `package.json`, and mount the parent into **both** the
   controller and every host (uncomment the volumes in `docker-compose.yml`):
   ```yaml
   volumes:
     - ./plugins:/clusterio/external_plugins
   ```
   The mount must be writable — the entrypoint npm-installs inside each plugin dir.
2. On container start, `install-plugins.sh` installs each plugin's production deps and
   **registers** it. Its full contract (non-fatal stderr WARNINGs, the `@clusterio` strip) is
   documented in the README.

## The two rules that cost the most when unknown

1. **`@clusterio/*` must be peerDependencies, never dependencies.** Clusterio fatally rejects a
   duplicate `@clusterio/lib` — one vendored copy crashes every `clusterioctl` invocation
   cluster-wide. The entrypoint strips stray copies at boot as a backstop, but npm 7+
   auto-installs peer deps on a workstation `npm install`, so keep your host-side dev types in a
   directory *above* the plugin (they resolve via Node's upward walk) and never run a bare
   install inside the mounted plugin dir.
2. **Node plugin code is cached by the long-lived host process.** An `instance stop/start`
   re-patches the save-embedded **Lua** module but does **not** reload plugin **Node** code —
   the require cache keeps serving the old build (and it will even log "plugin initialized").
   After changing Node code: restart the **host container**, then follow the boot-race protocol
   below. (Same class: the controller caches its plugin code too — restart the controller
   container for controller-side changes.)

## The dev loop

```text
edit → build (tsc → dist/) → docker restart <host container>
     → wait healthy → clusterioctl instance stop/start   (boot-race protocol)
     → verify a NEW-code-only behavior (new log line / new column / new command)
```

- **Boot race**: an instance that auto-starts before its host finishes the controller handshake
  silently skips instance plugins — no error, IPC just goes nowhere. Always stop/start the
  instance after the container is healthy, then **prove the plugin loaded** by observing
  behavior only the new build has. "It responds" is not "it's your build" — consider stamping a
  build id into your plugin's status output.
- **Lua module changes** (save-patched): an instance stop/start alone is sufficient — the save
  is re-patched on start.

## Where the output goes

| What | Where |
|---|---|
| Instance-plugin log lines | controller: `/clusterio/logs/cluster/cluster-*.log` (NOT `docker logs`) |
| Host-side log lines | host: `/clusterio/logs/host/host-*.log` |
| Engine + module Lua output | the instance's `factorio-current.log` |
| clusterioctl access | `docker exec clusterio-controller npx clusterioctl --config /clusterio/tokens/config-control.json …` |

**Windows note**: run RCON / clusterioctl commands with leading-slash arguments (e.g. `/command`)
from PowerShell, not git-bash/MSYS — MSYS rewrites leading-slash args into filesystem paths,
silently corrupting the command.

## Worked example

[`solarcloud7/clustorio-atlas`](https://github.com/solarcloud7/clustorio-atlas) is a full
production plugin developed against these images — TypeScript instance plugin + save-patched Lua
module + ctl commands — including a deterministic deploy script (`tools/deploy-plugin.ps1`)
that encodes the loop above, and an `AGENTS.md` capturing the operational rules.
