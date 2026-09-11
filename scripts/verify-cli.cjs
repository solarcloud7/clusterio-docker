// Native offline smoke: temporary state and logs only; run as the runtime user.
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
assert.notEqual(process.getuid(), 0, "Run CLI verification as clusterio");
const [role, expectedJson, ...extra] = process.argv.slice(2);
assert.equal(extra.length, 0, "verify-cli.cjs ROLE [EXPECTED_PLUGINS_JSON]");
const expected = expectedJson === undefined ? null : JSON.parse(expectedJson);
assert.ok(expected === null || (Array.isArray(expected) && expected.every(n => typeof n === "string") && new Set(expected).size === expected.length));
assert.ok(["host", "controller"].includes(role));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "clusterio-cli-"));
try {
  const binary = "/clusterio/node_modules/.bin/clusterio" + role;
  const args = ["--log-level", "error", "--log-directory", path.join(dir, "logs"),
    "--config", path.join(dir, "config.json"), "--plugin-list", path.join(dir, "plugins.json")];
  const run = (...command) => execFileSync(binary, [...args, ...command], {encoding: "utf8", timeout: 30000});
  const field = role + ".allow_remote_updates";
  run("config", "set", field, "false");
  assert.equal(run("config", "show", field).trim(), "false");
  run("config", "set", field, "true");
  assert.equal(run("config", "show", field).trim(), "true");
  // Strings are raw values, not JSON strings. Test token/path reads used on restart.
  if (role === "host") {
    for (const [key, value] of [["host.controller_token", "header.payload.signature"], ["host.factorio_directory", "/opt/test path"]]) {
      run("config", "set", key, value);
      assert.equal(run("config", "show", key).trim(), value);
    }
  }
  fs.writeFileSync(path.join(dir, "plugins.json"), "[]");
  run("plugin", "list");
  const entries = JSON.parse(fs.readFileSync(path.join(dir, "plugins.json")));
  const found = entries.map(([name]) => name).sort();
  require("./check-plugin-resolution.cjs").verifyPlugins(entries);
  if (expected !== null) assert.deepEqual(found, [...expected].sort(), "Native discovery must match explicit expected plugins");
  console.log(JSON.stringify({role, version: require("node:module").createRequire("/clusterio/package.json")("@clusterio/" + role + "/package.json").version,
    plugins: found, expectedPlugins: expected, selectionVerified: expected !== null, sharedDependenciesVerified: true}));
} finally { fs.rmSync(dir, {recursive: true, force: true}); }
