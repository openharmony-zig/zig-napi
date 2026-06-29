const fs = require("fs");
const path = require("path");

const packageName = "__PACKAGE_NAME__";
const binaryName = "__ADDON_NAME__";
let nativeBinding = null;
const loadErrors = [];

function requireNative() {
  if (process.env.NAPI_RS_NATIVE_LIBRARY_PATH) {
    try {
      return require(process.env.NAPI_RS_NATIVE_LIBRARY_PATH);
    } catch (error) {
      loadErrors.push(error);
    }
  }

  for (const platformArchABI of detectPlatformArchABIs()) {
    const binding = requireTuple(platformArchABI);
    if (binding) {
      return binding;
    }
  }
}

function requireTuple(platformArchABI) {
  try {
    return require(path.join(__dirname, "zig-out", "node", `${binaryName}.${platformArchABI}.node`));
  } catch (error) {
    loadErrors.push(error);
  }
  try {
    return require(path.join(__dirname, `${binaryName}.${platformArchABI}.node`));
  } catch (error) {
    loadErrors.push(error);
  }
  try {
    return require(optionalPackageName(packageName, platformArchABI));
  } catch (error) {
    loadErrors.push(error);
  }
}

nativeBinding = requireNative();

// NAPI_RS_FORCE_WASI is a tri-state flag:
//   unset / any other value -> native binding preferred, WASI is only a fallback
//   'true'                  -> force WASI fallback even if native loaded
//   'error'                 -> force WASI and throw if no WASI binding is found
const forceWasi =
  process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";

if (!nativeBinding || forceWasi) {
  let wasiBinding = null;
  let wasiBindingError = null;
  try {
    wasiBinding = require(path.join(__dirname, "zig-out", "node", `${binaryName}.wasi.cjs`));
    nativeBinding = wasiBinding;
  } catch (error) {
    if (forceWasi) {
      wasiBindingError = error;
    }
  }
  if (!nativeBinding || forceWasi) {
    try {
      wasiBinding = require(path.join(__dirname, `${binaryName}.wasi.cjs`));
      nativeBinding = wasiBinding;
    } catch (error) {
      if (forceWasi) {
        if (!wasiBindingError) {
          wasiBindingError = error;
        } else {
          wasiBindingError.cause = error;
        }
        loadErrors.push(error);
      }
    }
  }
  if (!nativeBinding || forceWasi) {
    try {
      wasiBinding = require(optionalPackageName(packageName, "wasm32-wasi"));
      nativeBinding = wasiBinding;
    } catch (error) {
      if (forceWasi) {
        if (!wasiBindingError) {
          wasiBindingError = error;
        } else {
          wasiBindingError.cause = error;
        }
        loadErrors.push(error);
      }
    }
  }
  if (process.env.NAPI_RS_FORCE_WASI === "error" && !wasiBinding) {
    const error = new Error("WASI binding not found and NAPI_RS_FORCE_WASI is set to error");
    error.cause = wasiBindingError;
    throw error;
  }
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

if (!nativeBinding) {
  if (loadErrors.length > 0) {
    const error = new Error(
      "Cannot find native binding. npm has a bug related to optional dependencies (https://github.com/npm/cli/issues/4828). Please try `npm i` again after removing both package-lock.json and node_modules directory.",
    );
    error.cause = loadErrors.reduce((err, cur) => {
      cur.cause = err;
      return cur;
    });
    throw error;
  }
  throw new Error("Failed to load native binding");
}

module.exports = nativeBinding;
module.exports.add = nativeBinding.add;
module.exports.hello = nativeBinding.hello;
