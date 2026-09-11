// Runs offline inside the candidate host image, as clusterio. Real CLI, no mocks.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {nativeConfig,reconcile,applyChanges,effective} = require("/scripts/configure-host.cjs");
assert.notEqual(process.getuid(),0);
const dir=fs.mkdtempSync(path.join(os.tmpdir(),"native-host-"));
const config=path.join(dir,"host.json"), token=path.join(dir,"host.token");
try {
  const cli=nativeConfig(config);
  reconcile(config,"/opt/factorio","clusterio-host-08",token,{CLUSTERIO_HOST_TOKEN:"header.payload.signature"});
  assert.equal(cli.read()["host.id"],8);
  assert.equal(cli.read()["host.factorio_port_range"],"34800-34899");
  cli.write("host.name","operator name"); cli.write("host.instances_directory",path.join(dir,"custom"));
  reconcile(config,"/opt/factorio","clusterio-host-1",token,{CLUSTERIO_HOST_TOKEN:"new.payload.signature"});
  assert.equal(cli.read()["host.name"],"operator name");
  assert.equal(cli.read()["host.instances_directory"],path.join(dir,"custom"));
  assert.equal(cli.read()["host.controller_token"],"new.payload.signature");
  cli.write("host.id",21); cli.write("host.controller_url","http://effective:8080/");
  assert.equal(effective(config),"21\nhttp://effective:8080/");
  const before=fs.readFileSync(config,"utf8");
  assert.throws(()=>applyChanges(cli,new Map([["host.id","not-a-number"]])), /did not accept/);
  assert.equal(fs.readFileSync(config,"utf8"),before);
  fs.writeFileSync(config,"broken JSON");
  assert.throws(()=>reconcile(config,"/opt/factorio","host-1",token,{}), /configuration command failed/);
  assert.equal(fs.readFileSync(config,"utf8"),"broken JSON");
  console.log(JSON.stringify({nativeConfiguration:"passed", invalidWriteRejected:true, unreadableConfigPreserved:true}));
} finally { fs.rmSync(dir,{recursive:true,force:true}); }
