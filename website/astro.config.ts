import { satteri } from "@astrojs/markdown-satteri";
import { defineConfig } from "astro/config";

import { SITE } from "./src/consts";
import { apiDocs } from "./src/data/api-docs";
import { normalizeBasePath } from "./src/lib/base-path";
import { kamiCodeTheme } from "./src/lib/kami-code-theme";
import { markdownDocs } from "./src/lib/markdown-docs";

/**
 * Deployment paths.
 *
 * `SITE_BASE_PATH` accepts an empty value, `/`, `/zig-napi/`, or a nested
 * path; `SITE_URL` optionally overrides the origin used for canonical URLs.
 * The GitHub Pages workflow passes the repository sub-path it derives itself.
 */
const base = normalizeBasePath(process.env.SITE_BASE_PATH);
const site = process.env.SITE_URL?.trim() || SITE.defaultOrigin;

export default defineConfig({
  site,
  base,
  output: "static",
  trailingSlash: "always",
  build: { format: "directory" },
  markdown: {
    // Heading anchors, table scrolling, and cross-document links are resolved
    // while the pages are built.
    processor: satteri({
      // The published documents are copied verbatim: keep straight quotes,
      // apostrophes, and dashes as they are written in the Markdown sources.
      features: { smartPunctuation: false },
      hastPlugins: [markdownDocs({ base, docIds: apiDocs.map((doc) => doc.id) })],
    }),
    // Highlighting happens during the build; no highlighter ships to the browser.
    shikiConfig: { theme: kamiCodeTheme },
  },
});
