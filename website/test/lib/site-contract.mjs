// Shared migration contract for the Astro/Kami documentation site.
//
// This module is the independent oracle used by `test/static.test.mjs` and
// `test/browser.mjs`. It deliberately does not import anything from the site
// implementation sources: the English copy, the topic ids, the route order and
// navigation names below were captured from the pre-migration site and are
// asserted as an external contract. The 15 pre-migration topics and their
// published heading anchors stay in place; `wasm-runtime` is the one added
// topic and is listed where it is published, in the Build group.
//
// The canonical Markdown under `website/src/content/{api,snippets}` is the
// content oracle: headings, prose blocks and code fences are compared against
// the rendered HTML. Nothing here shells out to git, and nothing touches the
// network.

import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const WEBSITE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// The heading ids the pages published before the migration, captured from a
// browser render and checked in as a fixture (`published-anchors.json`). This
// is a fixed contract, not a derivation: outside links point at these ids, and
// a renamed or deleted one has to fail the suite instead of quietly
// re-baselining itself. New headings are checked against the canonical
// Markdown separately (see `legacyHeadingSlugs`).
export const PUBLISHED_ANCHORS = JSON.parse(
  readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "published-anchors.json"),
    "utf8",
  ),
);

/** Number of heading ids the fixture pins (120, the published set). */
export const PUBLISHED_ANCHOR_TOTAL = PUBLISHED_ANCHORS.total;

/**
 * Compares the fixed published-anchor fixture against the ids a built page
 * exposes (`idsByTopic`: topic id -> Set of element ids). A published id may
 * appear literally or percent-encoded, which is how the previous renderer
 * slugged headings containing punctuation.
 */
export function publishedAnchorProblems(anchors, idsByTopic) {
  const problems = [];
  let checked = 0;
  for (const [topicId, ids] of Object.entries(anchors.topics)) {
    const pageIds = idsByTopic.get(topicId) ?? new Set();
    for (const id of ids) {
      checked += 1;
      if (!pageIds.has(id) && !pageIds.has(encodeURIComponent(id))) {
        problems.push(`${topicId}: #${id} is missing from the built page`);
      }
    }
  }
  return { checked, problems };
}

// Canonical content locations. The migration keeps these directories as they
// were; a source that is not there is a failure, not something to search for.
export const API_SOURCE_DIR = "src/content/api";
export const SNIPPET_SOURCE_DIR = "src/content/snippets";

// ---------------------------------------------------------------------------
// Routes and topic metadata
// ---------------------------------------------------------------------------

// Canonical reading order. This is the flattened group order of the previous
// site (Entry, Build, TypeScript, Values, Control Flow, Native State).
export const TOPICS = [
  { id: "overview", group: "Entry", navTitle: "Overview" },
  { id: "conversion-model", group: "Entry", navTitle: "Conversion Model" },
  { id: "module-registration", group: "Entry", navTitle: "Module Registration" },
  { id: "build-openharmony", group: "Build", navTitle: "OpenHarmony Build" },
  { id: "build-node", group: "Build", navTitle: "Node Addon Build" },
  { id: "wasm-runtime", group: "Build", navTitle: "WASM Runtime" },
  { id: "declaration-generation", group: "Build", navTitle: "Declaration Generation" },
  { id: "dts-overrides", group: "TypeScript", navTitle: "d.ts Overrides" },
  { id: "versioning", group: "TypeScript", navTitle: "Versioning" },
  { id: "values-primitives", group: "Values", navTitle: "Primitive Values" },
  { id: "values-objects", group: "Values", navTitle: "Objects And Arrays" },
  { id: "binary-data", group: "Values", navTitle: "Binary Data" },
  { id: "callback-functions", group: "Control Flow", navTitle: "Functions" },
  { id: "async-runtime", group: "Control Flow", navTitle: "Async Runtime" },
  { id: "classes-ownership", group: "Native State", navTitle: "Ownership" },
  { id: "errors-results", group: "Native State", navTitle: "Errors" },
];

// The 15 topics the site published before the WASM guide was added. Their
// routes and heading anchors are a published contract and never move.
export const LEGACY_TOPIC_IDS = [
  "overview",
  "conversion-model",
  "module-registration",
  "build-openharmony",
  "build-node",
  "declaration-generation",
  "dts-overrides",
  "versioning",
  "values-primitives",
  "values-objects",
  "binary-data",
  "callback-functions",
  "async-runtime",
  "classes-ownership",
  "errors-results",
];

export const TOPIC_IDS = TOPICS.map((topic) => topic.id);

// Group headings are user-visible navigation copy that the migration keeps.
export const GROUP_ORDER = [
  "Entry",
  "Build",
  "TypeScript",
  "Values",
  "Control Flow",
  "Native State",
];

// Accessible names of the three navigation landmarks, as the site published
// them before the migration.
export const NAV_NAMES = {
  apiSections: "API sections",
  tableOfContents: "On this page",
  documentPager: "API document navigation",
};

// The overview page is also the `/api/` index. Every other topic has its own
// directory; `/api/<id>` without a trailing slash is the same page.
export function routesForTopic(id) {
  if (id === "overview") {
    return { route: "api/", acceptedAliases: ["api/overview/"] };
  }
  return { route: `api/${id}/`, acceptedAliases: [`api/${id}`] };
}

export function topicById(id) {
  return TOPICS.find((topic) => topic.id === id);
}

export function previousTopic(id) {
  const index = TOPIC_IDS.indexOf(id);
  return index > 0 ? TOPICS[index - 1] : undefined;
}

export function nextTopic(id) {
  const index = TOPIC_IDS.indexOf(id);
  return index >= 0 && index < TOPICS.length - 1 ? TOPICS[index + 1] : undefined;
}

// ---------------------------------------------------------------------------
// Environment / paths
// ---------------------------------------------------------------------------

export function normalizeBasePath(value) {
  const trimmed = (value ?? "").trim().replace(/^\/+|\/+$/g, "");
  return trimmed ? `/${trimmed}/` : "/";
}

export function siteBasePath(env = process.env) {
  return normalizeBasePath(env.SITE_BASE_PATH);
}

export function resolveDistDir(env = process.env, websiteRoot = WEBSITE_ROOT) {
  const configured = (env.WEBSITE_DIST_DIR ?? "").trim();
  if (!configured) return path.join(websiteRoot, "dist");
  return path.isAbsolute(configured) ? configured : path.resolve(websiteRoot, configured);
}

// Screenshots default to `website/.test-results` (overridable); the metrics
// report defaults outside the repository so test runs do not dirty the tree.
export function resolveScreenshotDir(env = process.env, websiteRoot = WEBSITE_ROOT) {
  const configured = (env.WEBSITE_SCREENSHOT_DIR ?? "").trim();
  if (!configured) return path.join(websiteRoot, ".test-results");
  return path.isAbsolute(configured) ? configured : path.resolve(websiteRoot, configured);
}

export function resolveReportDir(env = process.env) {
  const configured = (env.WEBSITE_TEST_REPORT_DIR ?? "").trim();
  if (configured) return path.resolve(configured);
  return path.join(process.env.TMPDIR || "/tmp", "zig-napi-website-tests");
}

// Map a route relative to the deployment base ("api/", "api/build-node/", "")
// to candidate files inside dist. Both `dir/index.html` and a plain
// `dir.html` are accepted, and real files (assets, favicons) are used as is.
export function candidateDistFiles(distDir, routeRelative) {
  const clean = routeRelative.replace(/^\/+|\/+$/g, "");
  const target = clean ? path.join(distDir, clean) : distDir;
  if (path.extname(clean)) return [target];
  return [path.join(target, "index.html"), `${target}.html`];
}

export function resolveDistFile(distDir, routeRelative) {
  for (const candidate of candidateDistFiles(distDir, routeRelative)) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Content sources (canonical Markdown = the oracle)
// ---------------------------------------------------------------------------

export const SNIPPETS = [
  { id: "install", label: "ZON install", file: "install.md" },
  { id: "openharmony", label: "OpenHarmony", file: "openharmony.md" },
  { id: "node", label: "Node addon", file: "node.md" },
  { id: "types", label: "Type definitions", file: "types.md" },
];

function readCanonicalSource(directory, fileName, websiteRoot) {
  const filePath = path.join(websiteRoot, directory, fileName);
  if (!existsSync(filePath)) {
    throw new Error(`canonical content source is missing: ${path.relative(websiteRoot, filePath)}`);
  }
  return { filePath, text: readFileSync(filePath, "utf8") };
}

export function loadApiDocs(websiteRoot = WEBSITE_ROOT) {
  return TOPICS.map((topic) => {
    const fileName = `${topic.id}.md`;
    const { filePath, text } = readCanonicalSource(API_SOURCE_DIR, fileName, websiteRoot);
    const { data, body } = parseFrontmatter(text);
    return {
      ...topic,
      fileName,
      filePath,
      source: text,
      frontmatter: data,
      title: data.title ?? topic.navTitle,
      headings: extractHeadings(body),
      codeBlocks: extractCodeBlocks(body),
      blocks: extractTextBlocks(body),
    };
  });
}

export function loadSnippets(websiteRoot = WEBSITE_ROOT) {
  return SNIPPETS.map((snippet) => {
    const { filePath, text } = readCanonicalSource(SNIPPET_SOURCE_DIR, snippet.file, websiteRoot);
    const { body } = parseFrontmatter(text);
    const codeBlocks = extractCodeBlocks(body);
    return {
      ...snippet,
      filePath,
      codeBlocks,
      code: codeBlocks.map((block) => block.code).join("\n"),
    };
  });
}

// ---------------------------------------------------------------------------
// Markdown parsing / normalisation
// ---------------------------------------------------------------------------

const NAMED_ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00a0",
  hellip: "\u2026",
  mdash: "\u2014",
  ndash: "\u2013",
  rsquo: "\u2019",
  lsquo: "\u2018",
  ldquo: "\u201c",
  rdquo: "\u201d",
  times: "×",
  laquo: "«",
  raquo: "»",
  copy: "©",
  reg: "®",
};

export function decodeEntities(text) {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, body) => {
    if (body.startsWith("#x") || body.startsWith("#X")) {
      const code = Number.parseInt(body.slice(2), 16);
      return Number.isFinite(code) ? String.fromCodePoint(code) : match;
    }
    if (body.startsWith("#")) {
      const code = Number.parseInt(body.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : match;
    }
    const named = NAMED_ENTITIES[body.toLowerCase()];
    return named ?? match;
  });
}

export function collapseWhitespace(text) {
  return text
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// Both sides of every text comparison go through this, so a renderer that
// normalises punctuation (or one that does not) compares equal: only genuinely
// missing or reordered text fails.
export function normalizeForCompare(text) {
  return collapseWhitespace(text)
    .replace(/[\u2018\u2019\u201b]/g, "'")
    .replace(/[\u201c\u201d]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/\u2026/g, "...");
}

export function containsText(haystack, needle) {
  return normalizeForCompare(haystack).includes(normalizeForCompare(needle));
}

function stripHtmlTags(text) {
  return text.replace(/<\/?[a-zA-Z][^>]*>/g, "");
}

function stripLinkAndEmphasisSyntax(text) {
  let out = text;
  out = out.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1");
  out = out.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
  out = out.replace(/\*\*\*([^*]+)\*\*\*/g, "$1");
  out = out.replace(/\*\*([^*]+)\*\*/g, "$1");
  out = out.replace(/\*([^*]+)\*/g, "$1");
  out = out.replace(/(^|[\s([{])__([^_]+)__(?=[\s)\]}.,;:!?]|$)/g, "$1$2");
  out = out.replace(/(^|[\s([{])_([^_]+)_(?=[\s)\]}.,;:!?]|$)/g, "$1$2");
  return out;
}

// Inline code is literal text: `**` or `[x](y)` inside backticks must survive
// untouched, while the emphasis and link syntax around a code span
// (`**`.single` runtime.**`, `[`Buffer`](#buffer)`) must still be stripped.
// Splitting on backticks cannot do both, so every code span is masked first and
// its exact text is restored last. The mask is a private-use character pair
// that no Markdown source contains; it is written as a code point so the
// fixture file stays plain ASCII.
const CODE_SPAN_OPEN = String.fromCharCode(0xe000);
const CODE_SPAN_CLOSE = String.fromCharCode(0xe001);
const CODE_SPAN_PATTERN = new RegExp(`${CODE_SPAN_OPEN}(\\d+)${CODE_SPAN_CLOSE}`, "g");

function maskCodeSpans(text) {
  const spans = [];
  let masked = "";
  let index = 0;
  while (index < text.length) {
    const character = text[index];
    // A backslash escapes the next character, so an escaped backtick is text.
    if (character === "\\" && index + 1 < text.length) {
      masked += text.slice(index, index + 2);
      index += 2;
      continue;
    }
    if (character !== "`") {
      masked += character;
      index += 1;
      continue;
    }
    let openEnd = index;
    while (openEnd < text.length && text[openEnd] === "`") openEnd += 1;
    const marker = openEnd - index;
    let cursor = openEnd;
    let closeStart = -1;
    while (cursor < text.length) {
      if (text[cursor] !== "`") {
        cursor += 1;
        continue;
      }
      let runEnd = cursor;
      while (runEnd < text.length && text[runEnd] === "`") runEnd += 1;
      // Only a run of the same length closes the span; a longer one is content.
      // There is no escape handling in here: a code span is literal, so a
      // backslash in front of a backtick does not protect it.
      if (runEnd - cursor === marker) {
        closeStart = cursor;
        break;
      }
      cursor = runEnd;
    }
    if (closeStart === -1) {
      // No closing run: those backticks are ordinary text.
      masked += text.slice(index, openEnd);
      index = openEnd;
      continue;
    }
    // A code span is literal text: line endings become spaces, one leading and
    // one trailing space are dropped unless the span is all spaces, and neither
    // backslash escapes nor entity references are interpreted — `&amp;` inside
    // a span stays the five characters it was written as.
    let content = text.slice(openEnd, closeStart).replace(/\r\n?|\n/g, " ");
    if (content.startsWith(" ") && content.endsWith(" ") && content.trim() !== "") {
      content = content.slice(1, -1);
    }
    spans.push(content);
    masked += `${CODE_SPAN_OPEN}${spans.length - 1}${CODE_SPAN_CLOSE}`;
    index = closeStart + marker;
  }
  return { masked, spans };
}

function restoreCodeSpans(text, spans) {
  return text.replace(CODE_SPAN_PATTERN, (match, index) => spans[Number(index)] ?? match);
}

// Convert one Markdown fragment (line, cell or paragraph) into the text a
// renderer would place in the document. Inline code keeps its literal text
// (`<T>`, `a*b*`, `__init__`, backticks and entity references included), raw
// inline HTML is dropped, links keep their label — including a label that is a
// code span — and entity references in ordinary text are decoded.
export function markdownInlineToText(text) {
  const { masked, spans } = maskCodeSpans(text);
  const stripped = decodeEntities(stripHtmlTags(stripLinkAndEmphasisSyntax(masked)));
  return restoreCodeSpans(stripped, spans);
}

export function extractHeadings(markdown) {
  const headings = [];
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  let fenceMarker = "";
  for (const line of lines) {
    const fence = /^\s*(`{3,}|~{3,})/.exec(line);
    if (fence) {
      if (!fenceMarker) fenceMarker = fence[1][0];
      else if (fence[1][0] === fenceMarker) fenceMarker = "";
      continue;
    }
    if (fenceMarker) continue;
    const heading = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (heading) {
      headings.push({
        depth: heading[1].length,
        text: collapseWhitespace(markdownInlineToText(heading[2])),
      });
    }
  }
  return headings;
}

// A fence indented inside a list item (or blockquote) has that indentation
// removed from its content before it is rendered, so the oracle has to dedent
// by the fence's own indentation as well.
function dedentCodeLine(line, indent) {
  let remaining = indent;
  let position = 0;
  while (remaining > 0 && position < line.length) {
    const character = line[position];
    if (character === " ") {
      position += 1;
      remaining -= 1;
    } else if (character === "\t") {
      position += 1;
      remaining = 0;
    } else {
      break;
    }
  }
  return line.slice(position);
}

export function extractCodeBlocks(markdown) {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let index = 0;
  while (index < lines.length) {
    const fence = /^([ \t]*)(`{3,}|~{3,})[ \t]*([\w+#.-]*)[ \t]*$/.exec(lines[index]);
    if (!fence) {
      index += 1;
      continue;
    }
    const indent = fence[1].replace(/\t/g, "    ").length;
    const marker = fence[2][0];
    const lang = fence[3] ?? "";
    const close = new RegExp(`^\\s*\\${marker}{3,}\\s*$`);
    const code = [];
    index += 1;
    while (index < lines.length && !close.test(lines[index])) {
      code.push(dedentCodeLine(lines[index], indent));
      index += 1;
    }
    index += 1;
    blocks.push({ lang, code: trimCode(code.join("\n")) });
  }
  return blocks;
}

// Code is compared exactly; only trailing whitespace and the blank lines a
// renderer may add around the block are ignored.
export function trimCode(code) {
  const lines = code
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/\s+$/, ""));
  while (lines.length && lines[0].trim() === "") lines.shift();
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  return lines.join("\n");
}

function makeTextBlock(text, type) {
  return { type, text: collapseWhitespace(markdownInlineToText(text)) };
}

// Extract the readable blocks of a Markdown document: paragraphs, list items
// and table cells (code fences and headings are returned separately).
export function extractTextBlocks(markdown) {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let paragraph = [];
  let listItem = null;

  const flushParagraph = () => {
    if (paragraph.length) {
      blocks.push(makeTextBlock(paragraph.join(" "), "paragraph"));
      paragraph = [];
    }
  };
  const flushList = () => {
    if (listItem) {
      blocks.push(makeTextBlock(listItem.join(" "), "listItem"));
      listItem = null;
    }
  };
  const flushAll = () => {
    flushParagraph();
    flushList();
  };

  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    const fence = /^\s*(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/.exec(line);
    if (fence) {
      flushAll();
      const marker = fence[1][0];
      const close = new RegExp(`^\\s*\\${marker}{3,}\\s*$`);
      index += 1;
      while (index < lines.length && !close.test(lines[index])) index += 1;
      index += 1;
      continue;
    }
    if (/^\s*$/.test(line)) {
      flushAll();
      index += 1;
      continue;
    }
    if (/^(#{1,6})\s+/.test(line)) {
      flushAll();
      index += 1;
      continue;
    }
    if (/^\s*\|/.test(line)) {
      flushAll();
      while (index < lines.length && /^\s*\|/.test(lines[index])) {
        const row = lines[index].trim();
        const isSeparator = /^\|[\s:|-]+\|?$/.test(row);
        if (!isSeparator) {
          for (const cell of row.replace(/^\|/, "").replace(/\|$/, "").split("|")) {
            const block = makeTextBlock(cell, "cell");
            if (block.text) blocks.push(block);
          }
        }
        index += 1;
      }
      continue;
    }
    const listMatch = /^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (listMatch) {
      flushParagraph();
      flushList();
      listItem = [listMatch[2]];
      index += 1;
      continue;
    }
    if (listItem && /^\s+\S/.test(line)) {
      listItem.push(line.trim());
      index += 1;
      continue;
    }
    if (/^\s*>/.test(line)) {
      flushList();
      paragraph.push(line.replace(/^\s*>\s?/, ""));
      index += 1;
      continue;
    }
    flushList();
    paragraph.push(line.trim());
    index += 1;
  }
  flushAll();
  return blocks;
}

// Heading anchors published by the renderer the site used before the
// migration (`markdown-it-anchor`'s default slug: trimmed, lower-cased,
// whitespace to "-", then percent-encoded, with repeats suffixed -1, -2, …).
// Fragments such as `#jserror%2C-jstypeerror%2C-jsrangeerror` were linked from
// outside the site, so the same slugs are re-derived here and checked against
// the built pages.
export function legacyHeadingSlug(text) {
  return encodeURIComponent(text.trim().toLowerCase().replace(/\s+/g, "-"));
}

/** The slug of every heading in a document, repeats disambiguated in order. */
export function legacyHeadingSlugs(headings) {
  const seen = new Set();
  return headings.map((heading) => {
    const base = legacyHeadingSlug(heading.text);
    let slug = base;
    let index = 1;
    while (seen.has(slug)) {
      slug = `${base}-${index}`;
      index += 1;
    }
    seen.add(slug);
    return slug;
  });
}

// Relative Markdown cross-links such as `[Ownership](./classes-ownership)`.
// The migration normalises these at render time instead of editing the
// Markdown, so the rendered href must become `/api/<topic>/`.
export function extractRelativeTopicLinks(markdown) {
  const links = [];
  const pattern = /\[([^\]]+)\]\(\.\/([a-z0-9-]+)(?:#[^)]*)?\)/g;
  let match;
  while ((match = pattern.exec(markdown))) {
    links.push({ label: collapseWhitespace(markdownInlineToText(match[1])), target: match[2] });
  }
  return links;
}

export function parseFrontmatter(source) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(source);
  if (!match) return { data: {}, body: source };
  const data = {};
  for (const line of match[1].split(/\r?\n/)) {
    const field = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (field) data[field[1]] = field[2].trim().replace(/^["']|["']$/g, "");
  }
  return { data, body: source.slice(match[0].length) };
}

// Prose fragments that must not appear in any shipped JavaScript file: finding
// them would mean the documentation body was shipped as a client-side bundle.
export function distinctiveProseSamples(docs, minimumLength = 60) {
  const samples = [];
  for (const doc of docs) {
    const block = doc.blocks?.find(
      (candidate) => candidate.type === "paragraph" && candidate.text.length >= minimumLength,
    );
    if (block) samples.push({ id: doc.id, text: block.text.slice(0, minimumLength) });
  }
  return samples;
}

// ---------------------------------------------------------------------------
// Home page English copy contract (captured from the pre-migration home page)
// ---------------------------------------------------------------------------

export const HOME_REQUIRED_COPY = [
  "OpenHarmony, Node.js, and WebAssembly addons",
  "Build N-API modules with Zig for OpenHarmony, Node.js, and WASI, and generate the matching TypeScript declarations from the same exported surface.",
  "Start with ZON",
  "API Reference",
  "Capability map",
  "One addon surface, multiple outputs",
  "Three runtime outputs",
  "Use one Zig export surface to build OpenHarmony shared libraries, Node.js addons, and WASI modules in single-threaded or threaded flavors.",
  "Typed JavaScript boundary",
  "Generate declaration files from functions, classes, enums, async descriptors, structs, and unions.",
  "N-API version gates",
  "Select Node-API v4 through v10 behavior and fail early when wrappers need a newer runtime API.",
  "Low-level escape hatches",
  "Work directly with Object, String, Buffer, ArrayBuffer, TypedArray, DataView, External, and references.",
  "Setup",
  "Install as a Zig package",
  "The package exports both the napi module and the napi_build helpers used by examples in this repository.",
  "zig fetch",
  "zig build",
  "zig build -Dtarget=aarch64-linux-ohos",
  "Build recipes",
  "Copy the shape that matches your target",
  "Type generation",
  "TypeScript declarations stay close to Zig exports",
  "Generated from Zig",
  "Functions, classes, tuples, structs, enums, arrays, unions, async descriptors, and raw N-API wrappers are mapped into declaration files during the build.",
  "Override when the public contract differs",
  'napi.dts(value, "TypeScriptType") and napi.Dts(T, "TypeScriptType") let exported declarations express a custom TypeScript-facing contract while keeping runtime values unchanged.',
  "Targets",
  "Build surface",
  "OpenHarmony",
  "aarch64-linux-ohos, arm-linux-ohoseabi, x86_64-linux-ohos",
  "Node.js",
  "host target by default, with platform-specific .node output names",
  "TypeScript",
  "index.d.ts generation from the same addon root",
  "Examples",
  "basic, init, node, allocator, memory, and benchmark fixtures",
  "WASI",
  "wasm32-wasip1 (single-threaded) and wasm32-wasip1-threads (shared memory) builds with generated wasi/wasip1 loaders",
  "Reference",
  "API docs live on their own path",
  "The standalone API reference covers module registration, build helpers, runtime values, binary wrappers, async descriptors, native ownership, errors, and custom TypeScript declaration overrides.",
  "Use the API page when you need exact Zig signatures and wrapper behavior instead of the overview flow.",
  "Open API Reference",
  "Inspired by napi-rs and node-addon-api",
];

// Copy that may be reworded as long as the fact stays: the footer keeps stating
// the project license (the previous site wrote "MIT licensed").
export const HOME_REQUIRED_PATTERNS = [
  {
    id: "license notice",
    pattern: /MIT\s+licen[cs]e[ds]?/i,
    expected: 'a footer notice naming the MIT license (previously "MIT licensed")',
  },
];

// Section headings must keep their previous reading order.
export const HOME_SECTION_ORDER = [
  "zig-napi",
  "One addon surface, multiple outputs",
  "Install as a Zig package",
  "Copy the shape that matches your target",
  "TypeScript declarations stay close to Zig exports",
  "Build surface",
  "API docs live on their own path",
];

// Anchors the home page has always exposed and that the acceptance flow uses.
export const HOME_REQUIRED_ANCHORS = ["install", "build"];
export const HOME_OPTIONAL_ANCHORS = ["types"];

export const HOME_NAV_LABELS = ["API", "GitHub"];
// The home page keeps the product logo. The build pipeline is rendered from
// source now, so the retired bitmap is no longer fetched by any page.
export const HOME_ASSETS = ["logo/icon-256.png"];
export const GITHUB_URL = "https://github.com/openharmony-zig/zig-napi";

// ---------------------------------------------------------------------------
// Home page build pipeline
// ---------------------------------------------------------------------------

// The figure is an overview: one shared root, the routes that are configured
// separately, the artifact each one produces, and a link into the guide that
// carries the detail. Labels are the copy a reader has to be able to read out
// of the rendered figure.
export const PIPELINE = {
  /** Id of the figure the home page renders in section 00. */
  figureId: "build-pipeline",
  labels: [
    "Shared root",
    "Zig export root",
    "src/hello.zig",
    "OpenHarmony",
    "napi_build.nativeAddonBuild",
    "libhello.so",
    "Node.js",
    "napi_build.nodeAddonBuild",
    "hello.<platform-arch-abi>.node",
    "WASI",
    "hello.wasm32-wasip1.wasm",
    "Unshared · no workers",
    "hello.wasm32-wasi.wasm",
    "Shared · worker pool",
    "Separate step",
    "TypeScript declarations",
    "napi_build.generateTypeDefinition",
    "index.d.ts",
  ],
  /** One guide per node; the route comes from the fixed topic map. */
  guides: [
    { topic: "build-openharmony", label: "OpenHarmony build guide" },
    { topic: "build-node", label: "Node addon build guide" },
    { topic: "wasm-runtime", label: "WASI runtime guide" },
    { topic: "declaration-generation", label: "Declaration generation guide" },
  ],
  // Detail the guides own, which the overview figure must not carry: command
  // lines, flag lists and runtime plugin behavior.
  deferredToGuides: [
    { pattern: /(?:zig build|zig-napi build|--target)/, expected: "build command lines" },
    { pattern: /@emnapi\/core/, expected: "the emnapi plugin detail" },
    { pattern: /SharedArrayBuffer/i, expected: "shared-memory requirements" },
  ],
  /** Retired bitmap artwork: no page may fetch it again. */
  retiredImage: "zig-napi-pipeline.svg",
};

// ---------------------------------------------------------------------------
// Key documentation capabilities (read from the canonical Markdown)
// ---------------------------------------------------------------------------

// Short factual patterns, matched against the Markdown source of each topic, so
// a guide cannot silently lose a capability the site documents today. They are
// deliberately not prose assertions: the wording stays the writer's.
export const KEY_DOC_FACTS = [
  {
    id: "overview",
    facts: [{ pattern: /wasm|WASI/, expected: "the WASI runtime route" }],
  },
  {
    id: "build-openharmony",
    facts: [
      { pattern: /napi_build\.nativeAddonBuild/, expected: "the OpenHarmony build helper" },
      { pattern: /aarch64-linux-ohos/, expected: "a supported OpenHarmony target triple" },
      { pattern: /OHOS_NDK_HOME/, expected: "the OHOS SDK resolution rule" },
    ],
  },
  {
    id: "build-node",
    facts: [
      { pattern: /napi_build\.nodeAddonBuild/, expected: "the Node addon build helper" },
      {
        pattern: /\.(darwin-arm64|linux-x64-gnu|win32-x64-msvc)\.node/,
        expected: "a platform .node output name",
      },
      { pattern: /nodePlatformArchAbi|platform-arch-abi/, expected: "the output-name helper" },
    ],
  },
  {
    id: "wasm-runtime",
    facts: [
      { pattern: /wasm32-wasip1-threads/, expected: "the threaded WASI target" },
      { pattern: /wasm32-wasip1(?!-)/, expected: "the single-threaded WASI target" },
      { pattern: /SharedArrayBuffer/i, expected: "the threaded flavor's memory requirement" },
      { pattern: /emnapi/, expected: "the emnapi runtime a WASI addon links" },
    ],
  },
  {
    id: "declaration-generation",
    facts: [
      { pattern: /napi_build\.generateTypeDefinition/, expected: "the declaration generator" },
      { pattern: /index\.d\.ts/, expected: "the declaration output file" },
    ],
  },
  {
    id: "async-runtime",
    facts: [
      { pattern: /ThreadSafeFunction/, expected: "thread-safe function support" },
      { pattern: /CancelToken|cancel/i, expected: "async cancellation" },
    ],
  },
  {
    id: "classes-ownership",
    facts: [
      { pattern: /ClassWithoutInit/, expected: "the no-init class shape" },
      { pattern: /NativeWrap|Reference/, expected: "native ownership handling" },
    ],
  },
  {
    id: "binary-data",
    facts: [
      { pattern: /ArrayBuffer/, expected: "ArrayBuffer support" },
      { pattern: /TypedArray/, expected: "typed-array support" },
    ],
  },
];

// Placeholders that must never survive into rendered prose. The two build
// recipe placeholders (`<GIT_TAG>`, `HASH_GOES_HERE`) are intentional sample
// syntax inside code and are asserted separately.
export const FORBIDDEN_PROSE_PATTERNS = [
  { name: "astro-island element", pattern: /<astro-island[\s>]/ },
  { name: "unresolved build token", pattern: /%[A-Z][A-Z0-9_]{2,}%/ },
  { name: "jsx interpolation", pattern: /\{\{|\}\}/ },
  // Uppercase only: `callback-functions.md` legitimately says "placeholder
  // values" in lowercase prose, while template leftovers are upper case.
  { name: "template placeholder", pattern: /\b(?:TODO|FIXME|TBD|XXX|PLACEHOLDER|LOREM IPSUM)\b/ },
  { name: "stringified object", pattern: /\[object Object\]/ },
];

export const EXPECTED_CODE_PLACEHOLDERS = ["<GIT_TAG>", "HASH_GOES_HERE"];
