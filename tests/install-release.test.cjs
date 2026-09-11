const {test} = require("node:test");
const assert = require("node:assert/strict");
const {packages, all} = require("../scripts/install-release.cjs");
test("default selection preserves all six bundled plugins", () => {
  assert.equal(packages("host", "2.0.0-alpha.27").length, 8);
  for (const name of all) assert.ok(packages("controller", "2.0.0-alpha.27").includes("@clusterio/plugin-" + name + "@2.0.0-alpha.27"));
});
test("minimal and subset use pinned native packages", () => {
  assert.deepEqual(packages("host", "2.0.0-alpha.27", "none"), ["@clusterio/host@2.0.0-alpha.27","@clusterio/ctl@2.0.0-alpha.27"]);
  assert.equal(packages("controller", "2.0.0-alpha.27", "global_chat,statistics_exporter").length, 4);
});
test("invalid selections and roles fail before npm runs", () => {
  for (const selection of ["", "all,none", "global_chat,global_chat", "../x", "--ignore-scripts"])
    assert.throws(() => packages("host", "2.0.0-alpha.27", selection));
  assert.throws(() => packages("bad", "2.0.0-alpha.27"));
  assert.throws(() => packages("host", "latest"));
});
