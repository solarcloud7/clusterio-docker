const fs = require("fs");
const path = require("path");

const asciiBanner = `+==========================================================+\nI WARNING:  This is the development branch for the 2.0     I\nI           version of clusterio.  Expect things to break. I\n+==========================================================+`;

const original = "    console.warn(`\n" + asciiBanner + "\n`);\n";
const wrapped = "    if (!process.env.CLUSTERIO_SUPPRESS_DEV_WARNING) {\n" +
  "        console.warn(`\n" + asciiBanner + "\n`);\n" +
  "    }\n";

// Support both global install and local node_modules
const baseDir = process.env.NODE_PATH || path.join(process.cwd(), "node_modules");

const targets = [
  "@clusterio/controller/dist/node/controller.js",
  "@clusterio/ctl/dist/node/ctl.js",
  "@clusterio/host/dist/node/host.js",
];

// pnpm monorepo paths (for custom builds from source)
const monorepoTargets = [
  "packages/controller/dist/node/controller.js",
  "packages/ctl/dist/node/ctl.js",
  "packages/host/dist/node/host.js",
];

// Resolve all candidate paths
const candidates = [
  ...targets.map(t => ({ label: t, file: path.join(baseDir, t) })),
  ...monorepoTargets.map(t => ({ label: t, file: path.join(process.cwd(), t) })),
];

for (const { label, file } of candidates) {
  if (!fs.existsSync(file)) {
    console.log(`Skipping ${label} (not found)`);
    continue;
  }
  let contents = fs.readFileSync(file, "utf8");
  if (contents.includes("CLUSTERIO_SUPPRESS_DEV_WARNING")) {
    console.log(`Already patched: ${label}`);
    continue;
  }
  // Normalize CRLF → LF (Windows-cloned source compiles with \r\n)
  contents = contents.replace(/\r\n/g, "\n");
  if (!contents.includes(original)) {
    console.warn(`WARNING: Unable to locate banner in ${label} - skipping`);
    continue;
  }
  contents = contents.replace(original, wrapped);
  fs.writeFileSync(file, contents, "utf8");
  console.log(`Patched: ${label}`);
}
