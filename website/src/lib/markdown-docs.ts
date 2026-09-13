import { createLegacySlugger } from "./legacy-anchors";

/**
 * Build-time Markdown transforms for the API documents, written against the
 * Sätteri hast plugin API that Astro 7 uses by default.
 *
 * 1. Heading anchors use the historical slug algorithm, so published
 *    `#fragment` links keep working after the migration. Astro's own heading
 *    pass runs after this one and keeps an id that is already set.
 * 2. Wide tables are wrapped in a scroll container, so a long row scrolls
 *    inside its own region instead of widening the page.
 * 3. Relative cross-document links written in the Markdown sources
 *    (`./classes-ownership`) resolve against the deployment base path instead
 *    of the current route. The Markdown sources themselves are never edited.
 */

/** Minimal hast shapes; the visitor boundary is otherwise untyped. */
type HastElement = {
  type: "element";
  tagName: string;
  properties?: Record<string, unknown>;
  children: unknown[];
};

type VisitorContext = {
  textContent(node: HastElement): string;
  setProperty(node: HastElement, key: string, value: unknown): void;
  wrapNode(node: HastElement, wrapper: HastElement): void;
};

export type MarkdownDocsOptions = {
  /** Deployment base path, always ending in `/` (e.g. `/` or `/zig-napi/`). */
  base: string;
  /** Ids of the API documents that relative links may point at. */
  docIds: string[];
};

const HEADING_TAGS = ["h1", "h2", "h3", "h4", "h5", "h6"];

export function markdownDocs(options: MarkdownDocsOptions) {
  // Plugin factories run once per document, so the slugger state is per page.
  return () => {
    const slugify = createLegacySlugger();

    return {
      name: "zig-napi-docs",
      element: [
        {
          filter: HEADING_TAGS,
          visit(node: unknown, context: unknown) {
            const heading = node as HastElement;
            const ctx = context as VisitorContext;
            ctx.setProperty(heading, "id", slugify(ctx.textContent(heading)));
          },
        },
        {
          filter: ["table"],
          visit(node: unknown, context: unknown) {
            (context as VisitorContext).wrapNode(node as HastElement, {
              type: "element",
              tagName: "div",
              properties: { className: ["table-scroll"] },
              children: [],
            });
          },
        },
        {
          filter: ["a"],
          visit(node: unknown, context: unknown) {
            const link = node as HastElement;
            const href = link.properties?.href;
            if (typeof href !== "string") return;

            const match = /^\.\.?\/+([^#?]*)([#?].*)?$/.exec(href);
            if (!match) return;

            const target = match[1].replace(/\.md$/, "");
            const suffix = match[2] ?? "";
            if (!target || !options.docIds.includes(target)) return;

            const path = target === "overview" ? "api/" : `api/${target}/`;
            (context as VisitorContext).setProperty(
              link,
              "href",
              `${options.base}${path}${suffix}`,
            );
          },
        },
      ],
    };
  };
}
