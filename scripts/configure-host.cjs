// Reconcile container inputs through the native CLI; preserve unrelated saved fields.
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

function nativeConfig(configPath) {
  const binary = "/clusterio/node_modules/.bin/clusteriohost";
  function run(args, input) {
    try {
      return execFileSync(binary, ["--log-level", "error", "--config", configPath, "config", ...args],
        { encoding: "utf8", input, timeout: 30000, maxBuffer: 1048576 });
    } catch {
      // Do not print execFileSync's error: it contains argv/output and may include credentials.
      throw new Error("Native host configuration command failed; inspect the host log. Configuration was retained.");
    }
  }
  return {
    read() {
      const values = {};
      for (const line of run(["list"]).trim().split(/\r?\n/)) {
        const separator = line.indexOf(" ");
        if (separator < 1) throw new Error("Invalid native host configuration output");
        const key = line.slice(0, separator);
        if (Object.hasOwn(values, key)) throw new Error("Duplicate native configuration field");
        try { values[key] = JSON.parse(line.slice(separator + 1)); }
        catch { throw new Error("Invalid native configuration value for " + key); }
      }
      for (const key of ["host.id", "host.name", "host.controller_url", "host.controller_token"]) {
        if (!Object.hasOwn(values, key)) throw new Error("Missing native configuration field: " + key);
      }
      return values;
    },
    write(key, value) { run(["set", key, "--stdin"], String(value)); },
  };
}
function hostId(hostName) {
  const id = Number(hostName.match(/[0-9]+$/)?.[0] || "1");
  if (!Number.isSafeInteger(id) || id < 0 || id > 2147483647)
    throw new Error("HOST_NAME must end in a valid numeric host ID");
  return id;
}
function explicit(env, key) {
  // Match the entrypoint's existing nonempty override convention (including .env templates).
  return env[key] || undefined;
}
function plan(values, { fresh, configPath, hostName, factorioDirectory, tokenFile, env }) {
  const writes = new Map();
  const id = fresh ? hostId(hostName) : values["host.id"];
  if (fresh) {
    writes.set("host.id", id);
    writes.set("host.name", hostName);
    writes.set("host.instances_directory", path.join(path.dirname(configPath), "instances"));
  }
  const controller = explicit(env, "CONTROLLER_URL");
  if (controller !== undefined || fresh) {
    writes.set("host.controller_url", controller ??
      "http://clusterio-controller:" + (env.CONTROLLER_HTTP_PORT || "8080") + "/");
  }
  const ports = explicit(env, "FACTORIO_PORT_RANGE");
  if (ports !== undefined || fresh) {
    const start = 34000 + id * 100;
    if (ports === undefined && start + 99 > 65535)
      throw new Error("Host ID requires an explicit FACTORIO_PORT_RANGE");
    writes.set("host.factorio_port_range", ports ?? start + "-" + (start + 99));
  }
  const token = explicit(env, "CLUSTERIO_HOST_TOKEN") ??
    (fs.existsSync(tokenFile) ? fs.readFileSync(tokenFile, "utf8").trim() : undefined) ??
    values["host.controller_token"];
  if (typeof token !== "string" || !/^[^.\s]+\.[^.\s]+\.[^.\s]+$/.test(token))
    throw new Error("No usable host token: supply CLUSTERIO_HOST_TOKEN or a token file. Configuration was retained.");
  writes.set("host.controller_token", token);
  writes.set("host.factorio_directory", factorioDirectory);
  return new Map([...writes].filter(([key, value]) => values[key] !== value));
}
function reconcile(configPath, factorioDirectory, hostName, tokenFile, env = process.env) {
  const fresh = !fs.existsSync(configPath);
  const cli = nativeConfig(configPath);
  const values = cli.read(); // Never replace an unreadable saved config with defaults.
  const writes = plan(values, { fresh, configPath, hostName, factorioDirectory, tokenFile, env });
  applyChanges(cli, writes);
  console.log(fresh ? "Host configured" : "Host configuration reconciled");
}
function applyChanges(cli, writes) {
  for (const [key, value] of writes) cli.write(key, value);
  const actual = cli.read();
  for (const [key, value] of writes) {
    if (actual[key] !== value)
      throw new Error("Native configuration did not accept " + key + "; startup stopped and configuration retained");
  }
}
function effective(configPath) {
  const values = nativeConfig(configPath).read();
  const id = values["host.id"], url = values["host.controller_url"];
  if (!Number.isSafeInteger(id) || id < 0 || id > 2147483647) throw new Error("Invalid effective host.id");
  if (typeof url !== "string" || /\s/.test(url) || !/^https?:\/\//.test(url))
    throw new Error("Invalid effective host.controller_url");
  return id + "\n" + url;
}
module.exports = { nativeConfig, hostId, plan, reconcile, applyChanges, effective };
if (require.main === module) {
  try {
    const [mode, configPath, ...args] = process.argv.slice(2);
    if (mode === "reconcile" && args.length === 3) reconcile(configPath, ...args);
    else if (mode === "effective" && args.length === 0) console.log(effective(configPath));
    else throw new Error("Usage: configure-host.cjs reconcile CONFIG FACTORIO_DIR HOST_NAME TOKEN_FILE | effective CONFIG");
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
