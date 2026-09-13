/**
 * Single source of truth for site metadata.
 *
 * Every value here is taken from the repository itself (README, LICENSE, the
 * published API documents). Nothing in this file is invented for marketing
 * purposes; pages must not fabricate facts that are absent from the sources.
 */

export const SITE = {
  name: "zig-napi",
  /** Eyebrow line used on the landing page and in the short site title. */
  category: "OpenHarmony and Node.js native addons",
  description:
    "Documentation website for zig-napi, a Zig toolkit for OpenHarmony and Node.js native addons.",
  repository: "https://github.com/openharmony-zig/zig-napi",
  license: "MIT",
  /** Fallback author/publisher for `<meta name="generator">`-free metadata. */
  defaultOrigin: "https://openharmony-zig.github.io",
  docsTitle: "API Reference",
} as const;

/** Locale of the shipped site. Only English is published. */
export const LOCALE = "en";
