const fs = require("fs");
const path = require("path");

function platformArchABIs() {
  const arch = process.arch;
  const variables =
    process.config && process.config.variables ? process.config.variables : {};

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

module.exports = function loadAddon(name) {
  const candidates = platformArchABIs().map((platformArchABI) =>
    path.join(__dirname, `${name}.${platformArchABI}.node`),
  );
  const loadErrors = [];

  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) {
      loadErrors.push(new Error(`Missing native binding ${candidate}`));
      continue;
    }

    try {
      return require(candidate);
    } catch (error) {
      loadErrors.push(error);
    }
  }

  throw new Error(
    [
      `Unable to load ${name}.node from: ${candidates.join(", ")}`,
      ...loadErrors.map((error) => `- ${error && error.message ? error.message : error}`),
    ].join("\n"),
  );
};
