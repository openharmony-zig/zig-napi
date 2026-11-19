const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const esbuild = require("esbuild");
const { Miniflare } = require("miniflare");

test(
  "a workerd request can instantiate, dispose and reload the threadless addon",
  { timeout: 60_000 },
  async (t) => {
    const project = path.resolve(__dirname, "../../examples/node");
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "zig-napi-workerd-"));
    t.after(() => fs.rm(dir, { recursive: true, force: true }));
    const worker = path.join(dir, "worker.mjs");
    await esbuild.build({
      stdin: {
        resolveDir: project,
        contents: `
        import { instantiate, dispose } from "./hello.wasip1-deferred.js";
        import wasm from "./hello.wasm32-wasip1.wasm";
        export default {
          async fetch() {
            const first = await instantiate(wasm);
            const value = first.add(20, 22);
            await dispose();
            const second = await instantiate(wasm);
            const fresh = second !== first;
            await dispose();
            return Response.json({ value, fresh, target: second.__napiBindingTarget });
          }
        };`,
      },
      platform: "browser",
      format: "esm",
      bundle: true,
      external: ["./hello.wasm32-wasip1.wasm"],
      outfile: worker,
    });
    const runtime = new Miniflare({
      compatibilityDate: "2026-06-01",
      modulesRoot: dir,
      modules: [
        { type: "ESModule", path: worker },
        {
          type: "CompiledWasm",
          path: path.join(dir, "hello.wasm32-wasip1.wasm"),
          contents: await fs.readFile(path.join(project, "hello.wasm32-wasip1.wasm")),
        },
      ],
    });
    try {
      const response = await runtime.dispatchFetch("https://test.local/");
      const body = await response.text();
      assert.equal(response.status, 200, body);
      assert.deepEqual(JSON.parse(body), { value: 42, fresh: true, target: "wasm32-wasip1" });
    } finally {
      await runtime.dispose();
    }
  },
);
