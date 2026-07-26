# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. We aim to acknowledge reports within a few days.

## Supported versions

Only the latest published images are maintained:

- `ghcr.io/solarcloud7/clusterio-docker-controller`
- `ghcr.io/solarcloud7/clusterio-docker-host`

Use the `:latest` tag or a specific published version tag. Older tags are not
back-patched.

## Secrets & credentials

- **Never commit a real `.env`.** It is gitignored; only `.env.example` is
  tracked. Factorio credentials (`FACTORIO_USERNAME` / `FACTORIO_TOKEN`) and the
  admin username belong in `.env` or runtime environment variables only — never
  in the image or git history.
- Prefer the **runtime** game-client download (set `FACTORIO_USERNAME` /
  `FACTORIO_TOKEN` as host env vars) over the build-time `INSTALL_FACTORIO_CLIENT`
  path — the runtime path keeps credentials out of the build entirely.
- When you must bake the client, credentials go in as **BuildKit secrets**
  (`--secret id=factorio_username,env=… --secret id=factorio_token,env=…`), never
  build args. The `FACTORIO_CLIENT_USERNAME` / `FACTORIO_CLIENT_TOKEN` build args
  were removed precisely because `--build-arg` values are readable via
  `docker history` (see CLAUDE.md, pitfall #8). Such images must stay private.
- Seeded database files (`seed-data/controller/database/users.json`,
  `roles.json`) are gitignored — only the `*.example.json` templates are tracked.

## Cluster tokens & the shared-tokens trust boundary

The `shared-tokens` volume (`/clusterio/tokens`) is how the controller hands
credentials to hosts. Know what it contains before you treat a host container as
a low-privilege sandbox:

- **`config-control.json` is a cluster-ADMIN credential.** It is minted for
  `INIT_CLUSTERIO_ADMIN`, whose seeded role holds `core.admin` — a wildcard that
  satisfies every one of Clusterio's 85 permission checks, including
  `core.instance.send_rcon` (arbitrary in-game command execution), instance
  deletion, and user/role editing.
- **Every host mounts that volume**, so every host container can read the admin
  credential *and* every other host's token. The mount is `:ro`, so a compromised
  host can read tokens but cannot mint or alter them.
- Token files are `0600` and owned by `clusterio` (uid 1001, identical in both
  images). CI asserts both the mode and that hosts can still read them.
- The boot-race guard needs controller API access, so it derives a rewritten copy
  at `/clusterio/data/.guard-control.json`. That copy is `0600` and **removed on
  every guard exit path** — it must not outlive the boot.

**Practical consequence:** external Clusterio plugins run as Node inside the host
process with full filesystem access, so an untrusted plugin on any host is one
file read away from cluster admin. Treat third-party plugins as trusted code, or
run them on a cluster you are willing to lose. (Factorio's own Lua is sandboxed
and is *not* a path to these files.)

There is currently **no token rotation path** — generation happens only in the
controller's first-run block, so rotating means wiping the controller volume.

## Factorio

These images run [Factorio](https://factorio.com), which is proprietary software
licensed by Wube Software Ltd. Factorio is obtained from official channels; you
are responsible for complying with the [Factorio Terms of
Service](https://factorio.com/terms-of-service).
