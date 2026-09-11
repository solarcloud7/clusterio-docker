// Native container acceptance. All resources belong to this run; no live cluster access.
import assert from "node:assert/strict";
import {execFileSync, spawnSync} from "node:child_process";
import {mkdirSync, writeFileSync, cpSync, readFileSync} from "node:fs";
import {resolve, join} from "node:path";
import {randomUUID, createHash} from "node:crypto";
const [controllerImage, hostImage, ...flags] = process.argv.slice(2);
assert.ok(controllerImage && hostImage, "consumer-smoke.mjs CONTROLLER HOST [--plugins names|none] [--case name] [--skip-package] [--previous-host IMAGE]");
const options = {plugins:"none", case:"all"};
for(let i=0;i<flags.length;i++) {
  const key=flags[i];
  if(key==="--skip-package") options.skipPackage=true;
  else if(["--plugins","--case","--previous-host"].includes(key)) {
    assert.ok(flags[i+1] && !flags[i+1].startsWith("--"), "Missing value for "+key);
    options[key.slice(2)]=flags[++i];
  } else throw Error("Unknown option "+key);
}
const cases=["lifecycle","rotation","overrides","saved-identity","hook-identity","zero-id","failures","upgrade"];
assert.ok(options.case==="all" || cases.includes(options.case), "Unknown acceptance case");
const expected=options.plugins==="none"?[]:options.plugins.split(",").sort();
const run="cd-smoke-"+randomUUID().slice(0,12), label="clusterio-docker.smoke";
const directory=resolve("ci-artifacts",run); mkdirSync(directory,{recursive:true});
const report={schemaVersion:2,run,startedAt:new Date().toISOString(),checks:[],cases:[],cleanup:false,
  options, harnessSha256:createHash("sha256").update(readFileSync(new URL(import.meta.url))).digest("hex")};
const volumes=[], containers=[];
let network=false;
const redact=value=>String(value).replace(/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g,"[REDACTED]");
function docker(...args) {
  try { return execFileSync("docker",args,{encoding:"utf8",timeout:180000,maxBuffer:2097152,stdio:["pipe","pipe","pipe"]}).trim(); }
  catch(error) {
    // exec errors contain argv (including temporary tokens); never retain that object.
    throw Error("docker "+args[0]+" failed ("+(error.status??error.code)+"): "+redact(error.stderr||"").slice(-4000));
  }
}
const check=name=>{report.checks.push(name);console.log("PASS: "+name);};
async function until(read,description) {
  const end=Date.now()+150000;let last;
  while(Date.now()<end) {
    try {if(read())return;}catch(error){last=error.message;}
    await new Promise(r=>setTimeout(r,1000));
  }
  throw Error(description+" timed out"+(last?": "+last:""));
}
function owned(kind,name) {
  assert.ok(name.startsWith(run));
  const info=JSON.parse(docker(kind,"inspect",name))[0];
  assert.equal((kind==="container"?info.Config.Labels:info.Labels)?.[label],run);
}
function create(name,image,args=[]) {
  docker("create","--name",name,"--label",label+"="+run,...(network?["--network",run]:[]),...args,image);
  containers.push(name);
}
function remove(name) {
  owned("container",name);docker("rm","-f",name);containers.splice(containers.indexOf(name),1);
}
function local(name,role,...args) {
  return docker("exec","--user","clusterio",name,"/clusterio/node_modules/.bin/clusterio"+role,
    "--log-level","error","--config","/clusterio/data/config-"+role+".json",...args);
}
const ctl=run+"-controller",host=run+"-host";
const ctlArgs=["--network-alias","controller","--network-alias","alternate","-p","127.0.0.1::8080",
  "-e","INIT_CLUSTERIO_ADMIN=smoke","-e","HOST_COUNT=2","-e","EXPORT_HOST=0",
  ...["data","logs","mods","static","tokens"].flatMap(s=>["-v",run+"-controller-"+s+":/clusterio/"+s])];
const hostArgs=(env={},dataVolume=run+"-host-data")=>[
  ...Object.entries({HOST_NAME:"clusterio-host-1",CONTROLLER_URL:"http://controller:8080/",...env})
    .filter(([,v])=>v!==null).flatMap(([k,v])=>["-e",k+"="+v]),
  "-v",dataVolume+":/clusterio/data","-v",run+"-host-logs:/clusterio/logs",
  "-v",run+"-controller-tokens:/clusterio/tokens:ro"];
const hook=join(directory,"10-config.sh");
writeFileSync(hook,'set -eu\n[ "$(id -u)" -ne 0 ]\n/clusterio/node_modules/.bin/clusterio"$CLUSTERIO_ROLE" --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set "$CLUSTERIO_ROLE.allow_remote_updates" false\nif [ "$CLUSTERIO_ROLE" = host ] && [ ! -e /clusterio/data/hook-calls ]; then\n  /clusterio/node_modules/.bin/clusteriohost --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set host.name persisted-operator-name\nfi\nprintf "hook\\n" >> /clusterio/data/hook-calls\n');
function copyHook(name){docker("cp",hook,name+":/etc/clusterio/pre-start.d/10-config.sh");}
const health=name=>until(()=>JSON.parse(docker("inspect",name))[0].State.Health?.Status==="healthy",name+" health");
const token=id=>docker("exec",ctl,"cat","/clusterio/tokens/clusterio-host-"+id+".token");
const control=(...args)=>docker("exec","--user","clusterio",ctl,"/clusterio/node_modules/.bin/clusterioctl","--log-level","error","--config","/clusterio/tokens/config-control.json",...args);
async function restartHost(env={},extraHook,dataVolume) {
  if(containers.includes(host)) remove(host);
  create(host,report.images.host,hostArgs(env,dataVolume));copyHook(host);
  if(extraHook)docker("cp",extraHook,host+":/etc/clusterio/pre-start.d/20-case.sh");
  docker("start",host);await health(host);
}
async function scenario(name,fn) {
  if(options.case!=="all" && options.case!==name) return;
  const entry={name,status:"running",startedAt:new Date().toISOString()};report.cases.push(entry);
  try{await fn();entry.status="passed";check(name);}catch(error){entry.status="failed";throw error;}
  finally{entry.finishedAt=new Date().toISOString();}
}
try {
  report.images=Object.fromEntries([["controller",controllerImage],["host",hostImage]].map(([role,image])=>
    [role,docker("image","inspect",image,"--format","{{.Id}}")]));
  for(const [role,image] of Object.entries(report.images)) {
    const name=run+"-cli-"+role;
    docker("create","--name",name,"--label",label+"="+run,"--network","none","--user","clusterio",
      "--entrypoint","node",image,"/scripts/verify-cli.cjs",role,JSON.stringify(expected));containers.push(name);
    const output=docker("start","-a",name);
    assert.equal(JSON.parse(docker("inspect",name))[0].State.ExitCode,0,"Native CLI failed");
    (report.nativeCli??={})[role]=JSON.parse(output);
    assert.deepEqual(report.nativeCli[role].plugins,expected);check(role+" native CLI and explicit plugin selection");
    report[role+"BuildInfo"]=JSON.parse(docker("run","--rm","--network","none","--entrypoint","cat",image,"/clusterio/BUILD_INFO"));
  }
  if(options.case==="all") {
    const name=run+"-native-config";
    docker("create","--name",name,"--label",label+"="+run,"--network","none","--user","clusterio",
      "--entrypoint","node",report.images.host,"/tmp/native-host-config.cjs");containers.push(name);
    docker("cp","tests/native-host-config.cjs",name+":/tmp/native-host-config.cjs");
    docker("start","-a",name);
    assert.equal(JSON.parse(docker("inspect",name))[0].State.ExitCode,0,"Native configuration contract failed");
    check("native configuration rejection and preservation");
  }
  let consumer=report.images.controller;
  if(!options.skipPackage) {
    const context=join(directory,"consumer");mkdirSync(context);
    cpSync("seed-data/external_plugins/ci_fixture",join(context,"fixture"),{recursive:true,filter:p=>!p.includes("node_modules")});
    const baseTag=run+"-base";docker("tag",consumer,baseTag);
    const pack='const cp=require("child_process"); const result=JSON.parse(cp.execFileSync("npm",["pack","--json","--pack-destination","/tmp"],{cwd:"/tmp/fixture",encoding:"utf8"})); cp.execFileSync("npm",["install","--omit=dev","--no-audit","--no-fund","/tmp/"+result[0].filename],{cwd:"/clusterio",stdio:"inherit"});';
    writeFileSync(join(context,"install.cjs"),pack);
    writeFileSync(join(context,"Dockerfile"),"FROM "+baseTag+"\nUSER root\nCOPY fixture /tmp/fixture\nCOPY install.cjs /tmp/install.cjs\nRUN node /tmp/install.cjs\nUSER clusterio\nRUN node /scripts/verify-cli.cjs controller '"+JSON.stringify([...expected,"ci_fixture"].sort())+"'\nUSER root\n");
    const derived=run+"-consumer";docker("build","-t",derived,context);
    consumer=docker("image","inspect",derived,"--format","{{.Id}}");
    check("packaged plugin discovery and shared dependency resolution");
  } else report.packageCheck="skipped: base-image acceptance; packaged plugin tested separately";
  report.consumerImage=consumer;
  docker("network","create","--label",label+"="+run,run);network=true;
  for(const suffix of ["controller-data","controller-logs","controller-mods","controller-static","controller-tokens","host-data","host-logs"]) {
    const name=run+"-"+suffix;docker("volume","create","--label",label+"="+run,name);volumes.push(name);
  }
  async function startController() {create(ctl,consumer,ctlArgs);copyHook(ctl);docker("start",ctl);await health(ctl);}
  await startController();await restartHost();
  assert.equal(local(host,"host","config","show","host.name"),"persisted-operator-name");
  assert.equal(local(host,"host","config","show","host.allow_remote_updates"),"false");
  await scenario("lifecycle",async()=>{
    for(const dir of ["data","mods","static","logs"])
      docker("exec","--user","clusterio",ctl,"sh","-c","printf retained > /clusterio/"+dir+"/keep");
    remove(host);remove(ctl);await startController();await restartHost();
    for(const [name,role] of [[ctl,"controller"],[host,"host"]]) {
      assert.equal(local(name,role,"config","show",role+".allow_remote_updates"),"false");
      assert.equal(docker("exec",name,"cat","/clusterio/data/hook-calls"),"hook\nhook");
    }
    for(const dir of ["data","mods","static","logs"])
      assert.equal(docker("exec",ctl,"cat","/clusterio/"+dir+"/keep"),"retained");
    const port=docker("port",ctl,"8080/tcp");assert.match(port,/^127\.0\.0\.1:\d+$/);
    const response=await fetch("http://"+port+"/static/keep",{signal:AbortSignal.timeout(10000)});
    assert.equal(response.status,200);assert.equal(await response.text(),"retained");
  });
  await scenario("rotation",async()=>{
    const old=token(1), next=control("host","generate-token","--id","1");
    assert.notEqual(next,old,"Rotation requires a distinct token");
    await restartHost({CLUSTERIO_HOST_TOKEN:next});
    assert.equal(local(host,"host","config","show","host.controller_token"),next);
    assert.equal(local(host,"host","config","show","host.name"),"persisted-operator-name");
    // The stale file still exists: explicit environment credentials must win.
    assert.equal(token(1),old);
    await restartHost({CLUSTERIO_HOST_TOKEN:"",CONTROLLER_URL:"",FACTORIO_PORT_RANGE:""}); // Empty optional values also fall back.
    assert.equal(local(host,"host","config","show","host.controller_token"),old);
  });
  await scenario("overrides",async()=>{
    await restartHost({CONTROLLER_URL:"http://alternate:8080/",FACTORIO_PORT_RANGE:"35100-35199"});
    assert.equal(local(host,"host","config","show","host.controller_url"),"http://alternate:8080/");
    assert.equal(local(host,"host","config","show","host.factorio_port_range"),"35100-35199");
    await restartHost({CONTROLLER_URL:null});
    assert.equal(local(host,"host","config","show","host.controller_url"),"http://alternate:8080/");
    assert.equal(local(host,"host","config","show","host.factorio_port_range"),"35100-35199");
  });
  await scenario("saved-identity",async()=>{
    await restartHost({HOST_NAME:"clusterio-host-99",CONTROLLER_URL:null});
    assert.equal(local(host,"host","config","show","host.id"),"1");
    assert.equal(local(host,"host","config","show","host.name"),"persisted-operator-name");
  });
  await scenario("hook-identity",async()=>{
    const file=join(directory,"identity.sh");
    writeFileSync(file,'set -eu\ncli=/clusterio/node_modules/.bin/clusteriohost\n"$cli" --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set host.id 2\n"$cli" --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set host.controller_token --stdin < /clusterio/tokens/clusterio-host-2.token\n"$cli" --log-level error --config "$CLUSTERIO_CONFIG_PATH" config set host.controller_url http://alternate:8080/\n');
    await restartHost({},file);
    assert.equal(local(host,"host","config","show","host.id"),"2");
    assert.equal(local(host,"host","config","show","host.controller_url"),"http://alternate:8080/");
    // Restore both identity and its credential together before following cases.
    writeFileSync(file,readFileSync(file,"utf8").replace("host.id 2","host.id 1").replace("host-2.token","host-1.token"));
    await restartHost({},file);
  });
  await scenario("zero-id",async()=>{
    remove(host);
    const name=run+"-zero-id";
    create(name,report.images.host,["-e","HOST_NAME=clusterio-host-01","-e","CONTROLLER_URL=http://controller:8080/",
      "-e","CLUSTERIO_HOST_TOKEN="+token(1),"-v",run+"-controller-tokens:/clusterio/tokens:ro"]);
    docker("start",name);await health(name);
    assert.equal(local(name,"host","config","show","host.id"),"1");
    assert.equal(local(name,"host","config","show","host.factorio_port_range"),"34100-34199");
    remove(name);await restartHost();
  });
  await scenario("failures",async()=>{
    const name=run+"-bad-hook";
    create(name,report.images.host,["-e","CLUSTERIO_HOST_TOKEN=header.payload.signature","-e","HOST_NAME=clusterio-host-1"]);
    const bad=join(directory,"fail.sh");writeFileSync(bad,"exit 17\n");
    docker("cp",bad,name+":/etc/clusterio/pre-start.d/10-fail.sh");docker("start",name);
    await until(()=>JSON.parse(docker("inspect",name))[0].State.Status==="exited","failing hook");
    assert.equal(JSON.parse(docker("inspect",name))[0].State.ExitCode,17);
  });
  if(options["previous-host"]) await scenario("upgrade",async()=>{
    remove(host);
    const previous=docker("image","inspect",options["previous-host"],"--format","{{.Id}}");
    report.previousHostImage=previous;
    const name=run+"-previous-config";
    const dataVolume=run+"-upgrade-data";
    docker("volume","create","--label",label+"="+run,dataVolume);volumes.push(dataVolume);
    const script='const cp=require("child_process"),fs=require("fs");const config="/clusterio/data/config-host.json"; cp.execFileSync("chown",["clusterio:clusterio","/clusterio/data"]); for(const [key,value] of [["host.id","1"],["host.controller_url","http://controller:8080/"],["host.controller_token",fs.readFileSync("/clusterio/tokens/clusterio-host-1.token","utf8").trim()],["host.name","previous-image-operator"],["host.instances_directory","/clusterio/data/operator-instances"]]) cp.execFileSync("gosu",["clusterio","/clusterio/node_modules/.bin/clusteriohost","--log-level","error","--config",config,"config","set",key,"--stdin"],{input:value,stdio:["pipe","pipe","pipe"]}); fs.mkdirSync("/clusterio/data/operator-instances",{recursive:true});fs.writeFileSync("/clusterio/data/operator-instances/keep","retained");';
    docker("create","--name",name,"--label",label+"="+run,"--network","none","--user","root",
      "-v",dataVolume+":/clusterio/data","-v",run+"-controller-tokens:/clusterio/tokens:ro","--entrypoint","node",previous,"-e",script);containers.push(name);
    docker("start","-a",name);assert.equal(JSON.parse(docker("inspect",name))[0].State.ExitCode,0);
    // This case preserves prior-image configuration without the display-name fixture hook.
    create(host,report.images.host,hostArgs({},dataVolume));docker("start",host);await health(host);
    assert.equal(local(host,"host","config","show","host.name"),"previous-image-operator");
    assert.equal(local(host,"host","config","show","host.instances_directory"),"/clusterio/data/operator-instances");
    assert.equal(docker("exec",host,"cat","/clusterio/data/operator-instances/keep"),"retained");
    report.upgradeBoundary="Configuration written by previous native CLI, then candidate startup; no game or database migration";
  }); else if(options.case==="all" || options.case==="upgrade") {
    report.cases.push({name:"upgrade",status:"unverified",reason:"No --previous-host supplied"});
    if(options.case==="upgrade")throw Error("--case upgrade requires --previous-host");
  }
  report.coverageComplete=report.cases.every(entry=>entry.status==="passed");
  report.verdict="PASS";
} catch(error) {report.verdict="FAIL";report.error=redact(error.stack);process.exitCode=1;}
finally {
  const errors=[];
  for(const name of [...containers].reverse()) {
    try {
      owned("container",name);
      const output=spawnSync("docker",["logs","--tail","100",name],{encoding:"utf8",timeout:15000,maxBuffer:1048576});
      writeFileSync(join(directory,name+".log"),redact(String(output.stdout||"")+"\n"+String(output.stderr||"")).slice(-131072));
      if(output.error)(report.incompleteDiagnostics??=[]).push(name);
      docker("rm","-f",name);
    } catch(error){errors.push(error.message);}
  }
  for(const name of volumes) {try{owned("volume",name);docker("volume","rm",name);}catch(error){errors.push(error.message);}}
  if(network) {try{owned("network",run);docker("network","rm",run);}catch(error){errors.push(error.message);}}
  for(const kind of ["container","volume","network"]) {
    try {assert.equal(docker(...(kind==="container"?["ps","-aq"]:[kind,"ls","-q"]),"--filter","label="+label+"="+run),"");}
    catch(error){errors.push(error.message);}
  }
  report.cleanup=errors.length===0;report.cleanupErrors=errors;report.finishedAt=new Date().toISOString();
  if(!report.cleanup){report.verdict="FAIL";process.exitCode=1;}
  writeFileSync(join(directory,"result.json"),JSON.stringify(report,null,2)+"\n");
  console.log(JSON.stringify({verdict:report.verdict,cases:report.cases,cleanup:report.cleanup,error:report.error,report:join(directory,"result.json")},null,2));
}
