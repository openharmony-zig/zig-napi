#!/usr/bin/env node
const path = require("node:path");
const ts = require("typescript");
const root = path.resolve(__dirname, "..");
const files = ["test/declarations.ts", "examples/memory/index.d.ts"].map((file) =>
  path.join(root, file),
);
const program = ts.createProgram(files, {
  strict: true,
  noEmit: true,
  skipLibCheck: false,
  types: [],
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.NodeNext,
  moduleResolution: ts.ModuleResolutionKind.NodeNext,
});
const diagnostics = ts.getPreEmitDiagnostics(program);
if (diagnostics.length) {
  process.stderr.write(
    ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCanonicalFileName: (file) => file,
      getCurrentDirectory: () => root,
      getNewLine: () => "\n",
    }),
  );
  process.exitCode = 1;
} else {
  console.log("Generated declarations and public parity contracts passed TypeScript checks");
}
