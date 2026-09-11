const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {verifyPlugins} = require("../scripts/check-plugin-resolution.cjs");
test("duplicate lib resolution fails even when the duplicate has the same version", t => {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),"plugin-resolution-"));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  function pkg(dir, json, code="module.exports={};") {
    fs.mkdirSync(dir,{recursive:true});
    fs.writeFileSync(path.join(dir,"package.json"),JSON.stringify(json));
    fs.writeFileSync(path.join(dir,"index.js"),code);
  }
  pkg(root,{name:"runtime"});
  pkg(path.join(root,"node_modules/@clusterio/lib"),{name:"@clusterio/lib",version:"1.0.0"});
  const plugin=path.join(root,"node_modules/fixture");
  pkg(plugin,{name:"fixture"});
  assert.doesNotThrow(()=>verifyPlugins([["fixture","fixture"]],root));
  const duplicate=path.join(root,"node_modules/duplicate");
  pkg(duplicate,{name:"duplicate"});
  pkg(path.join(duplicate,"node_modules/@clusterio/lib"),{name:"@clusterio/lib",version:"1.0.0"});
  assert.throws(()=>verifyPlugins([["duplicate","duplicate"]],root), /duplicate @clusterio\/lib/);
});
