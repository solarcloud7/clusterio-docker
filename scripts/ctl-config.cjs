// Shared ctl-config helper for the entrypoints. Clusterio 2.0 renamed clusterioctl's
// config keys control.* -> ctl.*; both modes accept either key set and emit ctl.*.
//   migrate FILE                    rename the keys in place (atomic tmp+rename, idempotent)
//   derive  IN OUT CONTROLLER_URL   write a copy of IN to OUT with ctl.controller_url set
"use strict";
const fs = require("node:fs");

function renamed(file) {
  const out = {};
  for (const [key, value] of Object.entries(JSON.parse(fs.readFileSync(file, "utf8")))) {
    out[key.replace(/^control\./, "ctl.")] = value;
  }
  return out;
}
function writeAtomic(file, data) {
  // Hosts may read the shared file while this runs; never expose a partial write.
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(data, null, "\t"), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

const [mode, input, output, url] = process.argv.slice(2);
if (mode === "migrate" && input && output === undefined) {
  const data = renamed(input);
  if (typeof data["ctl.controller_token"] !== "string") throw new Error("no ctl.controller_token in " + input);
  writeAtomic(input, data);
} else if (mode === "derive" && input && output && url) {
  const data = renamed(input);
  data["ctl.controller_url"] = url;
  writeAtomic(output, data);
} else {
  console.error("Usage: ctl-config.cjs migrate FILE | derive IN OUT CONTROLLER_URL");
  process.exit(2);
}
