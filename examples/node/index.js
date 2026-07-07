const fs = require("fs");
const path = require("path");

const packageName = "zig-napi-node-example";
const binaryName = "hello";

function loadAddon() {
  const platformArchABI = detectPlatformArchABI();
  const optionalPackage = `${packageName}-${platformArchABI}`;
  const candidates = [
    () => require(optionalPackage),
    () => require(path.join(__dirname, `${binaryName}.${platformArchABI}.node`)),
    () => require(path.join(__dirname, "zig-out", "node", `${binaryName}.${platformArchABI}.node`)),
  ];

  const errors = [];
  for (const candidate of candidates) {
    try {
      return candidate();
    } catch (error) {
      errors.push(error);
    }
  }

  throw new Error(
    `Unable to load ${binaryName}.${platformArchABI}.node\n` +
      errors.map((error) => `- ${error.message}`).join("\n"),
  );
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
