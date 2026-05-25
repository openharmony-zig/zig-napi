const assert = require("assert").strict;
const fs = require("fs");
const path = require("path");

function loadAddon() {
  return loadAddonVariant("hello");
}

function addonCandidates(name) {
  const nodeOut = path.join(__dirname, "zig-out", "node");
  return fs
    .readdirSync(nodeOut, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(nodeOut, entry.name, `${name}.node`))
    .filter((candidate) => fs.existsSync(candidate));
}

function loadAddonVariant(name) {
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

const addon = loadAddon();

assert.equal(addon.add(20, 22), 42);
assert.equal(addon.hello(), "hello from node");
assert.equal(addon.requestedNapiVersion(), 8);
