const fs = require("fs");
const path = require("path");

const packageName = "zig-napi-node-example";
const binaryName = "hello";

function loadAddon() {
  const platformArchABI = detectPlatformArchABI();
  const optionalPackage = optionalPackageName(packageName, platformArchABI);
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
  const candidates =
    process.env.ZIG_NAPI_FORCE_WASI === "1" ? wasiCandidates : nativeCandidates.concat(wasiCandidates);

  const errors = [];
  for (const candidate of candidates) {
    try {
      return candidate();
    } catch (error) {
      errors.push(error);
    }
  }

  throw new Error(
    `Unable to load ${binaryName}.${platformArchABI}.node or ${binaryName}.wasm32-wasi.wasm\n` +
      errors.map((error) => `- ${error.message}`).join("\n"),
  );
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
