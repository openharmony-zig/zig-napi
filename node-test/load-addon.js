const fs = require("fs");
const path = require("path");

function platformArchABIs() {
  const arch = process.arch;
  const variables = process.config && process.config.variables ? process.config.variables : {};

  switch (process.platform) {
    case "darwin":
      return [`darwin-${arch}`];
    case "win32":
      if (variables.shlib_suffix === "dll.a" || variables.node_target_type === "shared_library") {
        return [`win32-${arch}-gnu`, `win32-${arch}-msvc`];
      }
      return [`win32-${arch}-msvc`, `win32-${arch}-gnu`];
    case "linux":
      return [`linux-${arch}-gnu`, `linux-${arch}-musl`];
    case "freebsd":
      return [`freebsd-${arch}`];
    default:
      return [`${process.platform}-${arch}`];
  }
}

function forceWasi() {
  return process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";
}

// Loader suffix per WASI flavor, matching napi-rs' `platformArchABI` mapping:
// the threaded flavor (shared memory, worker pool) is `wasm32-wasi` with a
// `*.wasi.cjs` loader, the single-threaded one is `wasm32-wasip1` with
// `*.wasip1.cjs`.
const WASI_FLAVORS = {
  wasi: "wasi",
  wasip1: "wasip1",
};

const DEFAULT_WASI_FLAVOR = "wasi";

/// Flavor requested through `ZIG_NAPI_WASI_FLAVOR`. Defaults to the threaded
/// flavor; an explicit value is strict — an unknown name is an error and a
/// missing loader for the requested flavor is reported instead of silently
/// loading the other flavor, because a test run must exercise one flavor only.
function wasiFlavor() {
  const requested = process.env.ZIG_NAPI_WASI_FLAVOR;
  if (requested === undefined || requested === "") return DEFAULT_WASI_FLAVOR;
  if (!Object.prototype.hasOwnProperty.call(WASI_FLAVORS, requested)) {
    throw new Error(
      `ZIG_NAPI_WASI_FLAVOR must be one of ${Object.keys(WASI_FLAVORS).join(", ")} ` +
        `(got ${JSON.stringify(requested)})`,
    );
  }
  return requested;
}

function wasiCandidates(name) {
  const suffix = WASI_FLAVORS[wasiFlavor()];
  return [
    path.join(__dirname, `${name}.${suffix}.cjs`),
    path.join(__dirname, "zig-out", "node", `${name}.${suffix}.cjs`),
  ];
}

module.exports = function loadAddon(name) {
  const nativeCandidates = platformArchABIs().flatMap((platformArchABI) => [
    path.join(__dirname, "zig-out", "node", `${name}.${platformArchABI}.node`),
    path.join(__dirname, `${name}.${platformArchABI}.node`),
  ]);
  const requestedFlavor = process.env.ZIG_NAPI_WASI_FLAVOR;
  const wasiRequested = forceWasi() || (requestedFlavor !== undefined && requestedFlavor !== "");
  const wasi = wasiCandidates(name);
  const candidates = wasiRequested ? wasi : nativeCandidates.concat(wasi);
  const loadErrors = [];

  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) {
      loadErrors.push(new Error(`Missing binding ${candidate}`));
      continue;
    }

    try {
      return require(candidate);
    } catch (error) {
      loadErrors.push(error);
    }
  }

  const expected = wasiRequested
    ? `a WASI ${WASI_FLAVORS[wasiFlavor()]} binding (${path.basename(wasi[0])}); build it with ` +
      (wasiFlavor() === "wasip1"
        ? "`zig-napi build --target wasm32-wasip1`"
        : "`zig-napi build --target wasm32-wasip1-threads`")
    : `${name}.node or ${path.basename(wasi[0])}`;
  throw new Error(
    [
      `Unable to load ${name}: expected ${expected}`,
      ...loadErrors.map((error) => `- ${error && error.message ? error.message : error}`),
    ].join("\n"),
  );
};

// Exposed for the ABI acceptance test, which pins the strict flavor selection.
module.exports.wasiFlavor = wasiFlavor;
module.exports.wasiCandidates = wasiCandidates;
