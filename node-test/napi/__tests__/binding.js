const fs = require("fs");
const path = require("path");

function addonCandidates(name) {
  const nodeOut = path.join(__dirname, "..", "..", "zig-out", "node");
  return fs
    .readdirSync(nodeOut, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(nodeOut, entry.name, `${name}.node`))
    .filter((candidate) => fs.existsSync(candidate));
}

function loadAddon(name) {
  for (const candidate of addonCandidates(name)) {
    try {
      return require(candidate);
    } catch (error) {
      if (error && error.code !== "ERR_DLOPEN_FAILED") {
        throw error;
      }
    }
  }

  throw new Error(`Unable to load a host-compatible ${name}.node`);
}

module.exports = loadAddon("example");
