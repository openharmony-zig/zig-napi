const fs = require("fs");
const path = require("path");

const packageName = "__PACKAGE_NAME__";
const binaryName = "__ADDON_NAME__";

function loadAddon() {
  const errors = [];
  if (process.env.NAPI_RS_NATIVE_LIBRARY_PATH) {
    try {
      return require(process.env.NAPI_RS_NATIVE_LIBRARY_PATH);
    } catch (error) {
      errors.push(error);
    }
  }

  for (const platformArchABI of detectPlatformArchABIs()) {
    const optionalPackage = optionalPackageName(packageName, platformArchABI);
    const candidates = [
      () => require(path.join(__dirname, `${binaryName}.${platformArchABI}.node`)),
      () => require(optionalPackage),
      () =>
        require(path.join(__dirname, "zig-out", "node", `${binaryName}.${platformArchABI}.node`)),
    ];

    for (const candidate of candidates) {
      try {
        return candidate();
      } catch (error) {
        errors.push(error);
      }
    }
  }

  throw new Error(
    `Unable to load ${binaryName} native binding\n` +
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

function detectPlatformArchABIs() {
  if (process.platform === "android") {
    if (process.arch === "arm64") return ["android-arm64"];
    if (process.arch === "arm") return ["android-arm-eabi"];
  }

  if (process.platform === "darwin") {
    if (process.arch === "x64") return ["darwin-universal", "darwin-x64"];
    if (process.arch === "arm64") return ["darwin-universal", "darwin-arm64"];
  }

  if (process.platform === "freebsd") {
    if (process.arch === "x64") return ["freebsd-x64"];
    if (process.arch === "arm64") return ["freebsd-arm64"];
  }

  if (process.platform === "linux") {
    const abi = isMusl() ? "musl" : "gnu";
    if (process.arch === "x64") return [`linux-x64-${abi}`];
    if (process.arch === "arm64") return [`linux-arm64-${abi}`];
    if (process.arch === "arm") return [`linux-arm-${abi === "musl" ? "musleabihf" : "gnueabihf"}`];
    if (process.arch === "loong64") return [`linux-loong64-${abi}`];
    if (process.arch === "riscv64") return [`linux-riscv64-${abi}`];
    if (process.arch === "ppc64") return ["linux-ppc64-gnu"];
    if (process.arch === "s390x") return ["linux-s390x-gnu"];
  }

  if (process.platform === "openharmony") {
    if (process.arch === "arm64") return ["openharmony-arm64"];
    if (process.arch === "x64") return ["openharmony-x64"];
    if (process.arch === "arm") return ["openharmony-arm"];
  }

  if (process.platform === "win32") {
    if (process.arch === "x64") return ["win32-x64-msvc"];
    if (process.arch === "ia32") return ["win32-ia32-msvc"];
    if (process.arch === "arm64") return ["win32-arm64-msvc"];
  }

  return [];
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
