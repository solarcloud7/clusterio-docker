const fs = require("fs");

const asciiBanner = `+==========================================================+\nI WARNING:  This is the development branch for the 2.0     I\nI           version of clusterio.  Expect things to break. I\n+==========================================================+`;

const original = "    console.warn(`\n" + asciiBanner + "\n`);\n";
const wrapped = "    if (!process.env.CLUSTERIO_SUPPRESS_DEV_WARNING) {\n" +
  "        console.warn(`\n" + asciiBanner + "\n`);\n" +
  "    }\n";

const targets = [
  "/usr/lib/node_modules/@clusterio/controller/dist/node/controller.js",
  "/usr/lib/node_modules/@clusterio/ctl/dist/node/ctl.js",
  "/usr/lib/node_modules/@clusterio/host/dist/node/host.js",
];

for (const file of targets) {
  let contents = fs.readFileSync(file, "utf8");
  if (contents.includes("CLUSTERIO_SUPPRESS_DEV_WARNING")) {
    continue;
  }
  if (!contents.includes(original)) {
    throw new Error(`Unable to locate banner in ${file}`);
  }
  contents = contents.replace(original, wrapped);
  fs.writeFileSync(file, contents, "utf8");
}
