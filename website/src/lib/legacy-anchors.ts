/**
 * Heading anchors.
 *
 * The site previously rendered its Markdown with `markdown-it-anchor`, which
 * slugs headings as `encodeURIComponent(text.trim().toLowerCase().replace(/\s+/g, "-"))`
 * and disambiguates repeats with `-1`, `-2`, … Published fragment URLs such as
 * `#result(t)` and `#jserror%2C-jstypeerror%2C-jsrangeerror` are linked from
 * outside the site, so the same algorithm runs at build time in
 * `markdown-docs.ts`.
 *
 * The table of contents never re-parses Markdown: it uses the headings Astro
 * returns from `render(entry)`, which carry these same ids.
 */

/** Legacy `markdown-it-anchor` default slugify. */
export function legacySlug(text: string): string {
  return encodeURIComponent(text.trim().toLowerCase().replace(/\s+/g, "-"));
}

/** Slugger with the same repeat handling as the previous renderer. */
export function createLegacySlugger() {
  const seen = new Set<string>();

  return (text: string): string => {
    const base = legacySlug(text);
    let slug = base;
    let index = 1;
    while (seen.has(slug)) {
      slug = `${base}-${index}`;
      index += 1;
    }
    seen.add(slug);
    return slug;
  };
}
