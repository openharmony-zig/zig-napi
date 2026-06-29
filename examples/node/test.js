const assert = require("assert").strict;
const addon = require("./index");

assert.equal(addon.add(20, 22), 42);
assert.equal(addon.hello(), "hello from node");
assert.equal(addon.requestedNapiVersion(), 8);
