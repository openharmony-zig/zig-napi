const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const ts = require("typescript");
const {
  createWasiBindingTypeDef,
  resolveWasmConfig,
  wasiMemoryBuildArgs,
} = require("../bin/wasi-templates.cjs");

test("WASI CJS declarations resolve real exports without importing themselves", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-types-"));
  try {
    const source =
      "export declare function add(a: number, b: number): number;\nexport declare class Box { readonly count: number; }\n";
    fs.writeFileSync(path.join(directory, "binding.d.cts"), createWasiBindingTypeDef(source));
    fs.writeFileSync(
      path.join(directory, "consumer.cts"),
      'import binding = require("./binding.cjs");\nconst n: number = binding.add(1, 2);\nconst count: number = new binding.Box().count;\n// @ts-expect-error must retain numeric parameter types\nbinding.add("wrong", 2);\n// @ts-expect-error readonly must survive CJS generation\nnew binding.Box().count = 1;\n',
    );
    const program = ts.createProgram([path.join(directory, "consumer.cts")], {
      noEmit: true,
      strict: true,
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.NodeNext,
      moduleResolution: ts.ModuleResolutionKind.NodeNext,
      types: [],
    });
    const diagnostics = ts.getPreEmitDiagnostics(program);
    assert.deepEqual(
      diagnostics.map((d) => ts.flattenDiagnosticMessageText(d.messageText, "\n")),
      [],
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("declaration rebasing handles references and nested import types without editing comments", () => {
  const source =
    '/// <reference path="./shared.d.ts" />\nexport type Value = import("./types.cjs").Box<import("../other.mjs").Item>;\n// import("./keep.js")\n';
  const actual = createWasiBindingTypeDef(
    source,
    "/project/index.d.ts",
    "/project/dist/binding.d.cts",
  );
  assert.match(actual, /reference path="\.\.\/shared.d.ts"/);
  assert.match(actual, /import\("\.\.\/types.cjs"\)/);
  assert.match(actual, /import\("\.\.\/\.\.\/other.mjs"\)/);
  assert.match(actual, /\/\/ import\("\.\/keep.js"\)/);
});

test("mode-dependent declarations fail while honest CommonJS forms remain valid", () => {
  for (const source of [
    "export default class Box {}",
    "export { Box as default };",
    'export type X = import("./types.js").X;',
    'import X = require("./types");',
    '/// <reference types="./types" />',
  ])
    assert.throws(() => createWasiBindingTypeDef(source), /CommonJS compatible/);
  for (const source of [
    'declare module "pkg" { export default class Box {} }',
    'export type * from "pkg";',
    'export type X = import("./types.js", { with: { "resolution-mode": "import" } }).X;',
  ])
    assert.equal(createWasiBindingTypeDef(source), source);
});

test("threadless initial memory controls both loader and linker independently", () => {
  const config = {
    wasm: { initialMemory: 4000, threadlessInitialMemory: 128, maximumMemory: 8192 },
  };
  assert.equal(resolveWasmConfig(config, true).initialMemory, 4000);
  assert.equal(resolveWasmConfig(config, false).initialMemory, 128);
  assert.deepEqual(wasiMemoryBuildArgs(config, false), [
    "-Dwasi-initial-memory-pages=128",
    "-Dwasi-max-memory-pages=8192",
  ]);
  assert.throws(() => resolveWasmConfig({ wasm: { threadlessInitialMemory: 65536 } }), /headroom/);
});
