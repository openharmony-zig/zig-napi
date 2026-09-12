// Diagnostic benchmark, not an RSS-sensitive CI assertion. Each workload runs
// in a fresh process so runtime startup/GC history is visible in its own sample.
// Run: node node-test/audit/hidden-risk-memory.cjs
const { spawnSync } = require("child_process");
const path = require("path");
const loader = path.resolve(__dirname, "../load-addon.js");

for (const observed of [false, true]) {
  const source = `
    const a=require(${JSON.stringify(loader)})('async_audit');
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
