# Container checks

Fast shell regressions:
```sh
bash tests/seed-instances-order.test.sh
bash tests/seed-mod-versions.test.sh
node --test tests/install-release.test.cjs
```

The [consumer startup check](../docs/consumer-integration.md#persistent-state-and-consumer-checks)
is manually runnable and part of PR CI. It uses actual native CLIs and labelled,
disposable Docker resources, with no game client or world startup.

Local acceptance on 2026-09-10: `cd-smoke-a4a21115-288` passed both minimal image
CLI checks, packaged controller plugin loading, first-boot and repeated hooks,
host settings and controller store retention after recreation, and failure-before-start.
Cleanup succeeded. The six default bundled plugins were also verified through the
native CLI in both full images. Existing shell regressions and the three plugin
selection tests passed.

The durable renamed-host fixture initially failed readiness
(`cd-smoke-9c789069-d5b`): the guard matched the environment name instead of the
registered host's ID. The corrected native-ID check passed the same fixture.
The initial get/show incompatibility is also covered by native CLI reads and by
requiring stored settings to survive the existing-host path.

Earlier harness errors are not product regressions: an absent empty plugin list,
Docker FROM requiring a tag rather than a bare image ID, and relying on a remote
name change being saved before shutdown. The final fixture writes its test setting
durably before the first server start.

The small controller-only fixture intentionally lacks a web bundle and host plugin;
its native warnings are expected. Full seeded integration remains responsible for
the supported default plugin combination and instance startup. This check does not
prove historical upgrades, whole-machine crash recovery or game cargo integrity.
