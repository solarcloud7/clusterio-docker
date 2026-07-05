# Asset Export — the Factorio game client & `export-data`

Clusterio's web UI needs icon spritesheets, prototype data, and locale strings that only the
**full game client** contains — the headless server ships no graphics. This repo automates the
whole flow: getting a client onto one host, and running `export-data` against it.

**Licensing**: the client is downloaded with **your** factorio.com credentials and is never
redistributed. Never push an image with a baked-in client to a public registry.

## How the host picks its Factorio directory (resolution order)

On every start, `host-entrypoint.sh` resolves `factorio_directory` in this order:

1. **Volume-installed client** (`/opt/factorio-client`, the external `factorio-client` volume) —
   preferred; survives `docker compose down -v`.
2. **Image-baked client** (only if the image was built with `INSTALL_FACTORIO_CLIENT=true` —
   private images only).
3. **Headless multi-version directory** — Clusterio auto-downloads the mod-pack's target
   headless version at runtime (no credentials needed).

Setting `SKIP_CLIENT=true` on a host forces option 3 even when a client is present (the default
for `clusterio-host-2` in the example compose).

## Getting the client: runtime download (recommended)

Set both credentials in `.env` (find your token at factorio.com → profile):

```bash
FACTORIO_USERNAME=your_username
FACTORIO_TOKEN=your_token
```

On next start, any host **without** `SKIP_CLIENT=true` that has no client yet downloads it into
the `factorio-client` volume (one-time, ~450 MB). Details that matter:

- `FACTORIO_CLIENT_BUILD` — `expansion` (default, includes Space Age) or `alpha` (base game).
- `FACTORIO_CLIENT_TAG` — `stable` (default) or a specific version.
- The token is passed to curl via a **stdin config** (`-K -`), so it never appears in the
  process list.
- Create the volume once before first use: `docker volume create factorio-client`.

The build-time alternative (`INSTALL_FACTORIO_CLIENT` build args in the dev overlay /
`Dockerfile.host`) exists for offline/private images — prefer the runtime path.

## Running the export: `EXPORT_HOST`

Set in `.env` (controller env):

```bash
EXPORT_HOST=1        # host ID that has the game client; 0/empty = skip export
```

During first-run seeding, the controller runs `clusterioctl instance export-data` **once**,
against the first auto-start instance on that host — retrying up to 60×10 s while the host
finishes booting (a fresh client download can take a while). Failure is a logged WARNING, not
fatal: the cluster still comes up, just without web-UI icons.

Run it manually any time (e.g. after a mod-pack change):

```bash
docker exec clusterio-controller npx clusterioctl \
  --config /clusterio/tokens/config-control.json \
  instance export-data <instance-name>
```

## What export-data produces

The default mod pack's `ExportManifest` assets, served to the web UI:

- `settings` / `prototypes` — JSON dumps of mod settings and all game prototypes
- `locale` — flattened en locale strings
- `spritesheet` — a single PNG containing all icon categories
- `metadata` — sprite coordinates + category membership (item, recipe, signal, technology,
  planet, quality, entity, static)

The extended per-category sheets are mainlined since Clusterio **alpha.23** (clusterio#838);
the web-UI consumption API changed in **alpha.24** (clusterio#875 — `useExportPrototypeMetadata`,
`FactorioIcon`). See [consumer-integration.md](consumer-integration.md).

## Troubleshooting

- **"Unable to find Factorio version X"** in the *host* log (not the instance's
  factorio-current.log): the resolved Factorio directory doesn't contain the version an
  instance pins. The entrypoint logs which version(s) it found at startup — compare against
  `factorio.version` in the instance config. A client install is a *single* version; keep the
  client's `FACTORIO_CLIENT_TAG` aligned with your instances' target version.
- **Export WARNING after 60 retries**: usually the client isn't installed on that host
  (credentials missing, or `SKIP_CLIENT=true`), or the instance failed to start — check the
  host log.
- **Icons missing/stale in the web UI** after changing mods: re-run `export-data` manually
  (see above) — seeding only runs it on first boot.
