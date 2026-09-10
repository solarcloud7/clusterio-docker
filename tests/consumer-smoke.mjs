// Disposable native startup test. No Factorio download or world startup.
import assert from "node:assert/strict";
import {execFileSync, spawnSync} from "node:child_process";
import {mkdirSync, writeFileSync, cpSync, readFileSync} from "node:fs";
import {resolve, join} from "node:path";
import {randomUUID, createHash} from "node:crypto";
const [controllerImage, hostImage, ...extra] = process.argv.slice(2);
assert.ok(controllerImage && hostImage && !extra.length, "consumer-smoke.mjs <minimal-controller-image> <minimal-host-image>");
const run = "cd-smoke-" + randomUUID().slice(0,12), label = "clusterio-docker.smoke";
const directory = resolve("ci-artifacts",run); mkdirSync(directory,{recursive:true});
const report = {schemaVersion:1,run,startedAt:new Date().toISOString(),checks:[],cleanup:false};
report.harnessSha256 = createHash("sha256").update(readFileSync(new URL(import.meta.url))).digest("hex");
const volumes=[], containers=[]; let network=false;
const docker=(...args)=>execFileSync("docker",args,{encoding:"utf8",timeout:120000,maxBuffer:2097152}).trim();
const check=name=>{report.checks.push(name);console.log("PASS: "+name);};
async function until(read,label) {
  const end=Date.now()+150000;let last;
  while(Date.now()<end) {try{if(read())return;}catch(e){last=e.message;}await new Promise(r=>setTimeout(r,1000));}
  throw new Error(label+" timed out: "+(last||"not ready"));
}
function owned(kind,name) {
  assert.ok(name.startsWith(run));
  const info=JSON.parse(docker(kind,"inspect",name))[0];
  assert.equal((kind==="container"?info.Config.Labels:info.Labels)?.[label],run);
}
function create(name,image,args=[]) {
  docker("create","--name",name,"--label",label+"="+run,"--network",run,...args,image);containers.push(name);
}
function local(name,role,...args) {
  return docker("exec","--user","clusterio",name,"/clusterio/node_modules/.bin/clusterio"+role,
    "--log-level","error","--config","/clusterio/data/config-"+role+".json",...args);
}
try {
  report.images=Object.fromEntries([["controller",controllerImage],["host",hostImage]].map(([role,image])=>
    [role,docker("image","inspect",image,"--format","{{.Id}}")]));
  for(const [role,image] of [["controller",controllerImage],["host",hostImage]]) {
    const name=run+"-cli-"+role;
    docker("create","--name",name,"--label",label+"="+run,"--network","none","--user","clusterio",
      "--entrypoint","node",image,"/scripts/verify-cli.cjs",role);containers.push(name);
    const output=docker("start","-a",name);
    assert.equal(JSON.parse(docker("inspect",name))[0].State.ExitCode,0,output);
    assert.deepEqual(JSON.parse(output).plugins,[]);check(role+" native CLI and minimal discovery");
  }
  // Install a real npm tarball, with no runtime source or plugin mount.
  const context=join(directory,"consumer");mkdirSync(context);
  cpSync("seed-data/external_plugins/ci_fixture",join(context,"fixture"),{recursive:true,filter:p=>!p.includes("node_modules")});
  const baseTag=run+"-base";docker("tag",report.images.controller,baseTag);
  writeFileSync(join(context,"Dockerfile"),"FROM "+baseTag+"\nUSER root\nCOPY fixture /tmp/fixture\nRUN cd /tmp/fixture && npm pack --pack-destination /tmp >/dev/null && cd /clusterio && npm install --omit=dev --no-audit --no-fund /tmp/ci_fixture-1.0.0.tgz && rm -rf /tmp/fixture /tmp/ci_fixture-1.0.0.tgz\n");
  const derived=run+"-consumer";docker("build","-t",derived,context);
  report.consumerImage=docker("image","inspect",derived,"--format","{{.Id}}");
  docker("network","create","--label",label+"="+run,run);network=true;
  for(const suffix of ["controller-data","controller-logs","mods","static","tokens","host-data","host-logs"]) {
    const name=run+"-"+suffix;docker("volume","create","--label",label+"="+run,name);volumes.push(name);
  }
  const ctl=run+"-controller",host=run+"-host";
  const ctlArgs=["--network-alias","controller","-p","127.0.0.1::8080",
    "-e","INIT_CLUSTERIO_ADMIN=smoke","-e","HOST_COUNT=1","-e","EXPORT_HOST=0",
    "-v",run+"-controller-data:/clusterio/data","-v",run+"-controller-logs:/clusterio/logs",
    "-v",run+"-mods:/clusterio/mods","-v",run+"-static:/clusterio/static","-v",run+"-tokens:/clusterio/tokens"];
  const hostArgs=["-e","HOST_NAME=clusterio-host-1","-e","CONTROLLER_URL=http://controller:8080/",
    "-v",run+"-host-data:/clusterio/data","-v",run+"-host-logs:/clusterio/logs","-v",run+"-tokens:/clusterio/tokens:ro"];
  const hook=join(directory,"10-config.sh");
  writeFileSync(hook,"set -eu\n[ \"$(id -u)\" -ne 0 ]\n/clusterio/node_modules/.bin/clusterio\"$CLUSTERIO_ROLE\" --log-level error --config \"$CLUSTERIO_CONFIG_PATH\" config set \"$CLUSTERIO_ROLE.allow_remote_updates\" false\nif [ \"$CLUSTERIO_ROLE\" = host ] && [ ! -e /clusterio/data/hook-calls ]; then\n  /clusterio/node_modules/.bin/clusteriohost --log-level error --config \"$CLUSTERIO_CONFIG_PATH\" config set host.name persisted-operator-name\nfi\nprintf \"hook\\n\" >> /clusterio/data/hook-calls\n");
  const copyHook=name=>docker("cp",hook,name+":/etc/clusterio/pre-start.d/10-config.sh");
  async function startController() {
    create(ctl,report.consumerImage,ctlArgs);copyHook(ctl);docker("start",ctl);
    await until(()=>JSON.parse(docker("inspect",ctl))[0].State.Health?.Status==="healthy","controller health");
  }
  await startController();
  create(host,report.images.host,hostArgs);copyHook(host);docker("start",host);
  await until(()=>JSON.parse(docker("inspect",host))[0].State.Health?.Status==="healthy","host health");
  for(const [name,role] of [[ctl,"controller"],[host,"host"]]) {
    assert.equal(local(name,role,"config","show",role+".allow_remote_updates"),"false");
    assert.equal(docker("exec",name,"cat","/clusterio/data/hook-calls"),"hook");
    docker("exec","--user","clusterio",name,"sh","-c","touch /clusterio/logs/ownership-probe");
  }
  assert.deepEqual(JSON.parse(docker("exec",ctl,"cat","/clusterio/plugin-list.json")).map(([n])=>n),["ci_fixture"]);
  assert.match(docker("logs",ctl),/ci_fixture controller plugin loaded/);
  check("fresh non-root startup, packaged plugin load, local-only hooks");
  assert.equal(local(host,"host","config","show","host.name"),"persisted-operator-name");
  docker("exec","--user","clusterio",ctl,"sh","-c",
    "printf state > /clusterio/data/keep; printf mod > /clusterio/mods/keep; printf asset > /clusterio/static/keep; printf log > /clusterio/logs/keep");
  const before=docker("inspect",ctl,"--format","{{.Id}}");

  for(const name of [host,ctl]) {owned("container",name);docker("rm","-f",name);containers.splice(containers.indexOf(name),1);}
  await startController();
  create(host,report.images.host,hostArgs);copyHook(host);docker("start",host);
  await until(()=>JSON.parse(docker("inspect",host))[0].State.Health?.Status==="healthy","recreated host health");
  assert.notEqual(docker("inspect",ctl,"--format","{{.Id}}"),before);
  assert.equal(local(host,"host","config","show","host.name"),"persisted-operator-name");
  assert.match(docker("logs",host),/Host already configured, starting/);
  for(const [name,role] of [[ctl,"controller"],[host,"host"]]) {
    assert.equal(docker("exec",name,"cat","/clusterio/data/hook-calls"),"hook\nhook");
    assert.equal(local(name,role,"config","show",role+".allow_remote_updates"),"false");
  }
  for(const [dir,value] of [["data","state"],["mods","mod"],["static","asset"],["logs","log"]])
    assert.equal(docker("exec",ctl,"cat","/clusterio/"+dir+"/keep"),value);
  const port=docker("port",ctl,"8080/tcp");assert.match(port,/^127\.0\.0\.1:\d+$/);
  const response=await fetch("http://"+port+"/static/keep",{signal:AbortSignal.timeout(10000)});
  assert.equal(response.status,200);assert.equal(await response.text(),"asset");
  check("recreation preserves host settings, tokens, mods, static assets and logs");
  const failed=run+"-bad-hook";
  create(failed,report.images.host,["-e","CLUSTERIO_HOST_TOKEN=header.payload.signature","-e","HOST_NAME=clusterio-host-1"]);
  const bad=join(directory,"fail.sh");writeFileSync(bad,"exit 17\n");
  docker("cp",bad,failed+":/etc/clusterio/pre-start.d/10-fail.sh");docker("start",failed);
  await until(()=>JSON.parse(docker("inspect",failed))[0].State.Status==="exited","failing hook");
  assert.equal(JSON.parse(docker("inspect",failed))[0].State.ExitCode,17);
  check("hook failure prevents server startup");report.verdict="PASS";
} catch(error) {report.verdict="FAIL";report.error=error.stack;process.exitCode=1;}
finally {
  const errors=[];
  for(const name of [...containers].reverse()) {
    try {
      owned("container",name);
      const output=spawnSync("docker",["logs","--tail","100",name],{encoding:"utf8",timeout:15000,maxBuffer:1048576});
      writeFileSync(join(directory,name+".log"),String(output.stdout||"")+"\n--- stderr ---\n"+String(output.stderr||""));
      docker("rm","-f",name);
    } catch(e) {errors.push(e.message);}
  }
  for(const name of volumes) {try {owned("volume",name);docker("volume","rm",name);}catch(e){errors.push(e.message);}}
  if(network) {try{owned("network",run);docker("network","rm",run);}catch(e){errors.push(e.message);}}
  for(const kind of ["container","volume","network"]) {
    try {assert.equal(docker(...(kind==="container"?["ps","-aq"]:[kind,"ls","-q"]),"--filter","label="+label+"="+run),"");}
    catch(e){errors.push(e.message);}
  }
  report.cleanup=errors.length===0;report.cleanupErrors=errors;report.finishedAt=new Date().toISOString();
  if(!report.cleanup){report.verdict="FAIL";process.exitCode=1;}
  writeFileSync(join(directory,"result.json"),JSON.stringify(report,null,2)+"\n");
  console.log(JSON.stringify({verdict:report.verdict,checks:report.checks,cleanup:report.cleanup,error:report.error,report:join(directory,"result.json")},null,2));
}
