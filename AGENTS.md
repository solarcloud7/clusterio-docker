# Working in this repository

Use the canonical checkout. Do not create worktrees, clones, or secondary repositories.

For startup, configuration, persistence, or recovery changes:
- Read the [configuration contract](docs/consumer-integration.md#host-configuration-precedence).
- Verify the pinned native CLI behavior, including failures; do not infer success from exit status alone.
- Exercise existing-state transitions, not only fresh startup. Use the scenarios and commands in [tests/README.md](tests/README.md).
- Keep credentials out of command output, reports and PR text.
- Record tested image identities and distinguish passed, failed and unverified cases.
- Recheck affected behavior after review fixes. Leave merging to the owner.

The acceptance runner owns only its labelled disposable resources. Never use it to reset a live cluster.
