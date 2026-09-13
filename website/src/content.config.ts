import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

/**
 * API documents and landing-page snippets are loaded straight from the
 * existing Markdown sources; the files are the published copy and are not
 * edited, duplicated, or generated.
 */
const api = defineCollection({
  loader: glob({
    pattern: "*.md",
    base: "./src/content/api",
    generateId: ({ entry }) => entry.replace(/\.md$/, ""),
  }),
  schema: z.object({
    title: z.string(),
  }),
});

const snippets = defineCollection({
  loader: glob({
    pattern: "*.md",
    base: "./src/content/snippets",
    generateId: ({ entry }) => entry.replace(/\.md$/, ""),
  }),
});

export const collections = { api, snippets };
