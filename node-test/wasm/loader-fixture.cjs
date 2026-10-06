const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// Optimized acceptance roots contain WASM only. Use the generated loader and
// its actual runtime dependencies with that exact artifact, never a fallback
// to the Debug binary beside the repository's loader.
module.exports = function stageLoader(root, binary, flavor) {
  const tests = path.resolve(__dirname, "..");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-wasm-loader-"));
  try {
    const abi = flavor === "wasi" ? "wasm32-wasi" : "wasm32-wasip1";
    fs.copyFileSync(
      path.join(root, `${binary}.${abi}.wasm`),
      path.join(directory, `${binary}.${abi}.wasm`),
    );
    const loader = `${binary}.${flavor}.cjs`;
    fs.copyFileSync(
      fs.existsSync(path.join(root, loader)) ? path.join(root, loader) : path.join(tests, loader),
      path.join(directory, loader),
    );
    if (flavor === "wasi")
      fs.copyFileSync(path.join(tests, "wasi-worker.mjs"), path.join(directory, "wasi-worker.mjs"));
    fs.symlinkSync(
      path.join(tests, "node_modules"),
      path.join(directory, "node_modules"),
      "junction",
    );
    return {
      loader: path.join(directory, loader),
      cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
    };
  } catch (error) {
    fs.rmSync(directory, { recursive: true, force: true });
    throw error;
  }
};
