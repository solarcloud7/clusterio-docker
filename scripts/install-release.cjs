const { execFileSync } = require("node:child_process");
const all = ["global_chat", "inventory_sync", "player_auth", "research_sync", "statistics_exporter", "subspace_storage"];
function packages(role, version, selection = "all") {
  if (!["host", "controller"].includes(role)) throw new Error("Invalid Clusterio role");
  if (!/^\d+\.\d+\.\d+(?:-[\w.]+)?$/.test(version)) throw new Error("Invalid Clusterio version");
  const names = selection === "all" ? all : selection === "none" ? [] : selection.split(",");
  if (new Set(names).size !== names.length || names.some(n => !all.includes(n)))
    throw new Error("CLUSTERIO_PLUGINS must be all, none, or unique comma-separated bundled plugin names");
  return [role, "ctl", ...names.map(n => "plugin-" + n)].map(n => "@clusterio/" + n + "@" + version);
}
module.exports = { packages, all };
if (require.main === module) {
  execFileSync("npm", ["install", "--omit=dev", "--no-audit", "--no-fund", ...packages(...process.argv.slice(2))],
    { stdio: "inherit" });
}
