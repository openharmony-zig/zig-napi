const fs = require("fs");
const path = require("path");

const packageName = "__PACKAGE_NAME__";
const binaryName = "__ADDON_NAME__";

function loadAddon() {
  const platformArchABI = detectPlatformArchABI();
  const optionalPackage = optionalPackageName(packageName, platformArchABI);
  const forceWasi =
    process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";
  const nativeCandidates = [
    () => require(path.join(__dirname, "zig-out", "node", `${binaryName}.${platformArchABI}.node`)),
    () => require(path.join(__dirname, `${binaryName}.${platformArchABI}.node`)),
    () => require(optionalPackage),
  ];
  const wasiCandidates = [
    () => require(path.join(__dirname, "zig-out", "node", `${binaryName}.wasi.cjs`)),
    () => require(path.join(__dirname, `${binaryName}.wasi.cjs`)),
    () => require(optionalPackageName(packageName, "wasm32-wasi")),
  ];
  const candidates = forceWasi ? wasiCandidates : nativeCandidates.concat(wasiCandidates);

  const errors = [];
  for (const candidate of candidates) {
    try {
      return candidate();
    } catch (error) {
      errors.push(error);
    }
  }

  const message =
    `Unable to load ${binaryName}.${platformArchABI}.node or ${binaryName}.wasm32-wasi.wasm\n` +
    errors.map((error) => `- ${error.message}`).join("\n");
  if (process.env.NAPI_RS_FORCE_WASI === "error") {
    throw new Error(`Unable to load forced WASI binding for ${binaryName}\n${message}`);
  }
  throw new Error(message);
}

function optionalPackageName(name, platformArchABI) {
  if (name.startsWith("@")) {
    const slash = name.indexOf("/");
    return `${name.slice(0, slash + 1)}${name.slice(slash + 1)}-${platformArchABI}`;
  }
  return `${name}-${platformArchABI}`;
}

function detectPlatformArchABI() {
  if (process.platform === "linux") {
    return `${process.platform}-${process.arch}-${isMusl() ? "musl" : "gnu"}`;
  }
  if (process.platform === "win32") {
    return `${process.platform}-${process.arch}-msvc`;
  }
  return `${process.platform}-${process.arch}`;
}

function isMusl() {
  if (process.report && typeof process.report.getReport === "function") {
    return !process.report.getReport().header.glibcVersionRuntime;
  }
  try {
    return fs.readFileSync("/usr/bin/ldd", "utf8").includes("musl");
  } catch {
    return false;
  }
}

module.exports = loadAddon();
