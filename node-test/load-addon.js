const fs = require("fs");
const path = require("path");

function platformArchABIs() {
  const arch = process.arch;

  switch (process.platform) {
    case "darwin":
      return [`darwin-${arch}`];
    case "win32":
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

  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) {
      continue;
    }

    try {
      return require(candidate);
    } catch (error) {
      if (error && error.code !== "ERR_DLOPEN_FAILED") {
        throw error;
      }
    }
  }

  throw new Error(`Unable to load ${name}.node from: ${candidates.join(", ")}`);
};
