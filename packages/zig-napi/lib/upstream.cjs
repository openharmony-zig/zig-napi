"use strict";

const api = require("@napi-rs/cli");

// Use the public parsers as well as the APIs: aliases, validation and defaults
// for language-independent commands belong to napi-rs.
const parsers = {
  "create-npm-dirs": api.createCreateNpmDirsCommand,
  artifacts: api.createArtifactsCommand,
  "pre-publish": api.createPrePublishCommand,
  prepublish: api.createPrePublishCommand,
  version: api.createVersionCommand,
  universalize: api.createUniversalizeCommand,
};

function parse(command, args) {
  const factory = parsers[command];
  if (!factory) return;
  if (args.some((arg) => arg === "--help" || arg === "-h")) {
    return {
      help: api.cli.usage(factory([]), { detailed: true }).replace(/\bnapi (?=\S)/g, "zig-napi "),
    };
  }
  return { options: factory(args).getOptions() };
}

module.exports = { api, parse, parsers };
