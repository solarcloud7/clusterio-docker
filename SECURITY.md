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
  path, which can leak credentials into image layers (see CLAUDE.md, pitfall #8).
- Seeded database files (`seed-data/controller/database/users.json`,
  `roles.json`) are gitignored — only the `*.example.json` templates are tracked.

## Factorio

These images run [Factorio](https://factorio.com), which is proprietary software
licensed by Wube Software Ltd. Factorio is obtained from official channels; you
are responsible for complying with the [Factorio Terms of
Service](https://factorio.com/terms-of-service).
