"use strict";

const { parseTriple } = require("@napi-rs/cli");
const { isWasiTargetName } = require("./wasi-templates.cjs");

function zigTarget(target) {
  if (!target || target === "native" || isWasiTargetName(target)) return target;
  // Zig triples already use these OS names without Rust's vendor component.
  if (
    /^[^-]+-(?:linux|macos|windows|freebsd|netbsd|openbsd)(?:-[^-]+)?$/.test(target) &&
    !/(?:android|androideabi)$/.test(target)
  )
    return target;
  const parsed = parseTriple(target);
  const arch =
    {
      x64: "x86_64",
      arm64: "aarch64",
      ia32: "x86",
      arm: "arm",
      loong64: "loongarch64",
      ppc64: "powerpc64le",
    }[parsed.arch] || parsed.arch;
  if (parsed.arch === "universal")
    throw new Error(
      "Build aarch64-apple-darwin and x86_64-apple-darwin, then run zig-napi universalize",
    );
  const os =
    { darwin: "macos", win32: "windows", android: "linux" }[parsed.platform] || parsed.platform;
  const abi =
    parsed.platform === "android"
      ? parsed.arch === "arm"
        ? "androideabi"
        : "android"
      : parsed.abi;
  return [arch, os, abi].filter(Boolean).join("-");
}

function platformId(target) {
  if (!target || target === "native")
    return `${process.platform}-${process.arch}${process.platform === "linux" ? (process.report.getReport().header.glibcVersionRuntime ? "-gnu" : "-musl") : process.platform === "win32" ? "-msvc" : ""}`;
  if (
    /^[^-]+-(?:linux|macos|windows|freebsd)(?:-[^-]+)?$/.test(target) &&
    !/(?:android|androideabi)$/.test(target)
  ) {
    const [cpu, os, abi] = target.split("-");
    const arch =
      {
        x86_64: "x64",
        aarch64: "arm64",
        x86: "ia32",
        loongarch64: "loong64",
        powerpc64le: "ppc64",
      }[cpu] || cpu;
    return [{ macos: "darwin", windows: "win32" }[os] || os, arch, abi].filter(Boolean).join("-");
  }
  return parseTriple(target).platformArchABI;
}

module.exports = { zigTarget, platformId };
