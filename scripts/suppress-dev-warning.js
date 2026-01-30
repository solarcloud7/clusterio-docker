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

for (const target of targets) {
  const file = path.join(baseDir, target);
  if (!fs.existsSync(file)) {
    console.log(`Skipping ${target} (not installed)`);
    continue;
  }
  let contents = fs.readFileSync(file, "utf8");
  if (contents.includes("CLUSTERIO_SUPPRESS_DEV_WARNING")) {
    console.log(`Already patched: ${target}`);
    continue;
  }
  if (!contents.includes(original)) {
    console.warn(`WARNING: Unable to locate banner in ${target} - skipping`);
    continue;
  }
  contents = contents.replace(original, wrapped);
  fs.writeFileSync(file, contents, "utf8");
  console.log(`Patched: ${target}`);
}
