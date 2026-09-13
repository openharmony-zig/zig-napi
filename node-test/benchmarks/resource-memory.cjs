// Diagnostic benchmark, not an RSS-sensitive CI assertion. Each workload runs
// in a fresh process so runtime startup/GC history is visible in its own sample.
// Run: node node-test/benchmarks/resource-memory.cjs
const { spawnSync } = require("child_process");
const path = require("path");
const loader = path.resolve(__dirname, "..", "load-addon.js");

for (const observed of [false, true]) {
  const source = `
    const a=require(${JSON.stringify(loader)})('async_tasks');
    const collect=async()=>{for(let i=0;i<10;i++){await new Promise(r=>setImmediate(r));global.gc();}};
    const snapshot=()=>({nativeBytes:a.activeBytes(),allocationCount:a.allocationCount(),rss:process.memoryUsage().rss});
    (async()=>{
      await collect(); const before=snapshot();let delivered=0;
      const started=process.hrtime.bigint();
      const task=a.asyncSliceEvents(3000,${observed ? "()=>{delivered++}" : "undefined"});
      const blockedUntil=Date.now()+300;
      while(Date.now()<blockedUntil){}
      const blocked=snapshot();
      const result=await task;
      const durationMs=Number(process.hrtime.bigint()-started)/1e6;
      await collect(); const after=snapshot();
      console.log(JSON.stringify({node:process.version,platform:process.platform,arch:process.arch,
        observed:${observed},events:3000,result,delivered,blockedMs:300,durationMs,before,blocked,after}));
    })().catch(error=>{console.error(error);process.exitCode=1});
  `;
  const result = spawnSync(process.execPath, ["--expose-gc", "-e", source], {
    encoding: "utf8",
    timeout: 15000,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error || result.signal || result.status !== 0) {
    console.error(result.error || `child failed: ${result.signal || result.status}`);
    process.exitCode = 1;
  }
}

for (const className of ["RetainedSummary", "TransientSummary"]) {
  const source = `
    const a=require(${JSON.stringify(loader)})('contracts');
    const collect=async()=>{for(let i=0;i<10;i++){await new Promise(r=>setImmediate(r));global.gc();}};
    (async()=>{
      await collect();const before=a.activeBytes();let instances=[];
      for(let i=0;i<100;i++)instances.push(i%2 ? a.${className}.make('x'.repeat(65536)) : new a.${className}('x'.repeat(65536)));
      await collect();const retained=a.activeBytes()-before;
      if(!instances.every(value=>value.length===65536))throw Error('invalid class output');
      instances=null;await collect();const after=a.activeBytes()-before;
      console.log(JSON.stringify({className:${JSON.stringify(className)},instances:100,inputBytes:6553600,retainedNativeBytes:retained,afterGcNativeBytes:after}));
    })().catch(error=>{console.error(error);process.exitCode=1});
  `;
  const result = spawnSync(process.execPath, ["--expose-gc", "-e", source], {
    encoding: "utf8",
    timeout: 15000,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error || result.signal || result.status !== 0) {
    console.error(result.error || `child failed: ${result.signal || result.status}`);
    process.exitCode = 1;
  }
}
