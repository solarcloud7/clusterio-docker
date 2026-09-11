const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {hostId, plan} = require("../scripts/configure-host.cjs");
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "host-contract-"));
  t.after(() => fs.rmSync(dir, {recursive:true, force:true}));
  return {fresh:false, hostName:"clusterio-host-2", factorioDirectory:"/opt/factorio",
    tokenFile:path.join(dir,"token"), configPath:"/data/host.json", env:{}};
}
const stored = {"host.id":7, "host.name":"operator", "host.controller_token":"saved.token.value",
  "host.controller_url":"http://saved:8080/", "host.factorio_port_range":"35100-35199",
  "host.factorio_directory":"/opt/factorio", "host.instances_directory":"/data/custom"};
test("unchanged restart preserves identity, custom directories, ports and endpoint", t => {
  assert.deepEqual([...plan(stored, fixture(t))], []);
});
test("explicit credentials override a stale file without resetting any saved field", t => {
  const options=fixture(t); fs.writeFileSync(options.tokenFile,"file.token.value");
  options.env.CLUSTERIO_HOST_TOKEN="new.token.value";
  assert.deepEqual([...plan(stored,options)], [["host.controller_token","new.token.value"]]);
  delete options.env.CLUSTERIO_HOST_TOKEN;
  assert.deepEqual([...plan(stored,options)], [["host.controller_token","file.token.value"]]);
});
test("explicit connection settings override saved values; absence preserves them", t => {
  const options=fixture(t); options.env.CONTROLLER_URL="http://other:8090/";
  options.env.FACTORIO_PORT_RANGE="36100-36199";
  assert.deepEqual([...plan(stored,options)], [
    ["host.controller_url","http://other:8090/"],["host.factorio_port_range","36100-36199"]]);
});
test("fresh identity and ports normalize decimal suffixes including 08", t => {
  const options=fixture(t); options.fresh=true; options.hostName="clusterio-host-08";
  const writes=plan(stored,options);
  assert.equal(writes.get("host.id"),8);
  assert.equal(writes.get("host.factorio_port_range"),"34800-34899");
  assert.equal(hostId("clusterio-host-01"),1);
  assert.throws(()=>hostId("host-99999999999999999999"), /valid numeric/);
});
test("invalid explicit input never silently falls back to saved credentials", t => {
  for(const [key,value] of [["CLUSTERIO_HOST_TOKEN","bad"],["CLUSTERIO_HOST_TOKEN","a..c"],["CLUSTERIO_HOST_TOKEN","a.b. c"]]) {
    const options=fixture(t); options.env[key]=value;
    assert.throws(()=>plan(stored,options));
  }
});

test("empty optional environment values retain the existing fallback behavior", t => {
  const options=fixture(t);
  options.env={CLUSTERIO_HOST_TOKEN:"",CONTROLLER_URL:"",FACTORIO_PORT_RANGE:""};
  assert.deepEqual([...plan(stored,options)],[]);
});
