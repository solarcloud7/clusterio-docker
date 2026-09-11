// Verify package resolution, rather than deleting possibly incompatible dependencies.
const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
function verifyPlugins(entries, root = "/clusterio") {
  const runtime = createRequire(path.join(root, "package.json"));
  const shared = ["@clusterio/lib", "@clusterio/web_ui"];
  for (const [name, spec] of entries) {
    const entry = runtime.resolve(path.isAbsolute(spec) ? spec : spec.startsWith(".") ? path.resolve(root, spec) : spec);
    const plugin = createRequire(entry);
    let dir = path.dirname(entry), pkg;
    while (true) {
      const file = path.join(dir, "package.json");
      if (fs.existsSync(file)) { pkg = JSON.parse(fs.readFileSync(file)); break; }
      const parent = path.dirname(dir);
      if (parent === dir) throw new Error("No package metadata for " + name);
      dir = parent;
    }
    for (const dependency of shared) {
      // lib is always shared; web_ui matters when the plugin declares it.
      if (dependency !== "@clusterio/lib" && !pkg.dependencies?.[dependency] && !pkg.peerDependencies?.[dependency]) continue;
      let expected, actual;
      try {
        expected = fs.realpathSync(runtime.resolve(dependency));
        actual = fs.realpathSync(plugin.resolve(dependency));
      } catch { throw new Error(name + ": cannot resolve required shared dependency " + dependency); }
      if (actual !== expected) throw new Error(name + ": duplicate " + dependency + "; install compatible peer dependencies");
      const range = pkg.peerDependencies?.[dependency];
      if (range && !range.startsWith("workspace:")) {
        const semver = runtime("semver");
        const version = JSON.parse(fs.readFileSync(runtime.resolve(dependency + "/package.json"))).version;
        if (!semver.satisfies(version, range, {includePrerelease:true})) throw new Error(name + ": incompatible peer requirement for " + dependency);
      }
    }
  }
}
module.exports = { verifyPlugins };
