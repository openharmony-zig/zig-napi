// Static acceptance tests for the Astro/Kami documentation site.
//
// Run from `website/`:
//
//     node --test test/static.test.mjs
//
// The tests only read an already built `dist/`; they never trigger a build.
// Configuration:
//   SITE_BASE_PATH        deployment base, normalised with a leading and
//                         trailing slash (default "/"); must match the base the
//                         dist was built for
//   WEBSITE_DIST_DIR      dist directory, absolute or relative to website/
//                         (default "dist")
//   WEBSITE_TEST_REPORT_DIR
//                         directory for the metrics JSON (default:
//                         $TMPDIR/zig-napi-website-tests, outside the repo)
//
// The content oracle is the canonical Markdown under
// `website/src/content/{api,snippets}` plus the captured English copy of the
// previous home page. Nothing here shells out to git, and nothing touches the
// network.

import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { after, before, describe, it } from "node:test";
import { parse } from "parse5";

import {
  EXPECTED_CODE_PLACEHOLDERS,
  FORBIDDEN_PROSE_PATTERNS,
  GITHUB_URL,
  GROUP_ORDER,
  HOME_ASSETS,
  HOME_NAV_LABELS,
  HOME_OPTIONAL_ANCHORS,
  HOME_REQUIRED_ANCHORS,
  HOME_REQUIRED_COPY,
  HOME_REQUIRED_PATTERNS,
  HOME_SECTION_ORDER,
  KEY_DOC_FACTS,
  LEGACY_TOPIC_IDS,
  NAV_NAMES,
  PIPELINE,
  PUBLISHED_ANCHORS,
  PUBLISHED_ANCHOR_TOTAL,
  TOPICS,
  TOPIC_IDS,
  collapseWhitespace,
  containsText,
  distinctiveProseSamples,
  extractRelativeTopicLinks,
  legacyHeadingSlugs,
  loadApiDocs,
  loadSnippets,
  markdownInlineToText,
  nextTopic,
  normalizeForCompare,
  previousTopic,
  publishedAnchorProblems,
  resolveDistDir,
  resolveDistFile,
  resolveReportDir,
  routesForTopic,
  siteBasePath,
} from "./lib/site-contract.mjs";

const base = siteBasePath();
const distDir = resolveDistDir();
const reportDir = resolveReportDir();
const docs = loadApiDocs();
const snippets = loadSnippets();
const docsById = new Map(docs.map((doc) => [doc.id, doc]));

// Budget for page-specific JavaScript. The contract is "each page downloads
// only its own code, never the whole React app or all article data", so the
// limit is deliberately generous for a small enhancement script and far below
// any framework runtime.
const MAX_PAGE_JS_BYTES = 48 * 1024;
const MAX_PAGE_SCRIPT_ELEMENTS = 6;

const metrics = {
  generatedAt: new Date().toISOString(),
  basePath: base,
  distDir,
  pages: {},
  totals: { pagesChecked: 0, internalLinks: 0, codeBlocks: 0, proseBlocks: 0 },
  issues: [],
  visualReview:
    "required: screenshots are produced by test/browser.mjs and must be reviewed by the leader",
};

// ---------------------------------------------------------------------------
// DOM helpers (parse5 is a direct dependency; a missing install fails loudly)
// ---------------------------------------------------------------------------

function fromParse5Node(node) {
  if (node.nodeName === "#text") return { tag: "#text", text: node.value };
  if (node.nodeName === "#comment" || node.nodeName === "#documentType") return undefined;
  const attrs = {};
  for (const attribute of node.attrs ?? []) attrs[attribute.name.toLowerCase()] = attribute.value;
  return {
    tag: (node.tagName ?? node.nodeName).toLowerCase(),
    attrs,
    children: (node.childNodes ?? []).map(fromParse5Node).filter(Boolean),
  };
}

function parseHtml(html) {
  return fromParse5Node(parse(html));
}

function walk(node, visit) {
  visit(node);
  for (const child of node.children ?? []) walk(child, visit);
}

function elements(root) {
  const found = [];
  walk(root, (node) => {
    if (node.tag && !node.tag.startsWith("#")) found.push(node);
  });
  return found;
}

function elementsByTag(root, tags) {
  const wanted = new Set(Array.isArray(tags) ? tags : [tags]);
  return elements(root).filter((element) => wanted.has(element.tag));
}

function attr(element, name) {
  return element.attrs?.[name];
}

function pageText(node, { skip = new Set(["script", "style", "template", "noscript"]) } = {}) {
  let text = "";
  const visit = (current, insideSkipped) => {
    if (current.tag === "#text") {
      if (!insideSkipped) text += current.text;
      return;
    }
    const skipHere = insideSkipped || (current.tag && skip.has(current.tag));
    for (const child of current.children ?? []) visit(child, skipHere);
  };
  visit(node, false);
  return text;
}

// Text a reader sees outside code samples: used for placeholder detection so
// intentional sample syntax such as `<GIT_TAG>` inside code is not flagged.
function proseText(node) {
  const skip = new Set(["script", "style", "template", "noscript", "pre", "code", "samp", "kbd"]);
  return collapseWhitespace(pageText(node, { skip }));
}

const documentIndex = new WeakMap();

function ownerDocument(node) {
  let current = node;
  while (current.parent) current = current.parent;
  return current;
}

function accessibleName(element) {
  const label = attr(element, "aria-label");
  if (label && label.trim()) return label.trim();
  const labelledBy = attr(element, "aria-labelledby");
  if (labelledBy) {
    // ARIA name from the referenced element's text.
    const root = ownerDocument(element);
    if (!documentIndex.has(root)) {
      const index = new Map();
      for (const candidate of elements(root)) {
        const id = attr(candidate, "id");
        if (id && !index.has(id)) index.set(id, candidate);
      }
      documentIndex.set(root, index);
    }
    const index = documentIndex.get(root);
    const text = labelledBy
      .trim()
      .split(/\s+/)
      .map((id) => index.get(id))
      .filter(Boolean)
      .map((target) => collapseWhitespace(pageText(target, { skip: new Set(["script", "style"]) })))
      .filter(Boolean)
      .join(" ");
    return text || labelledBy.trim();
  }
  return "";
}

function isMainLandmark(element) {
  return element.tag === "main" || attr(element, "role") === "main";
}

function navigationElements(root) {
  return elements(root).filter(
    (element) => element.tag === "nav" || attr(element, "role") === "navigation",
  );
}

function linkElements(root) {
  return elements(root).filter(
    (element) => element.tag === "a" && attr(element, "href") !== undefined,
  );
}

// ---------------------------------------------------------------------------
// Page loading, ids and link resolution
// ---------------------------------------------------------------------------

const pageCache = new Map();
const fileByteCache = new Map();

function fileBytes(filePath) {
  if (!fileByteCache.has(filePath)) fileByteCache.set(filePath, statSync(filePath).size);
  return fileByteCache.get(filePath);
}

function distIsPresent() {
  return existsSync(distDir) && statSync(distDir).isDirectory();
}

function requireDist() {
  assert.ok(
    distIsPresent(),
    `dist directory not found at ${distDir}.\n` +
      "Build the site first (the tests never trigger a build themselves):\n" +
      "  pnpm --filter zig-napi-website run build",
  );
}

function loadPage(routeRelative) {
  requireDist();
  if (pageCache.has(routeRelative)) return pageCache.get(routeRelative);
  const file = resolveDistFile(distDir, routeRelative);
  assert.ok(
    file,
    `expected ${path.join(distDir, routeRelative, "index.html")} to exist for route "${base}${routeRelative}"`,
  );
  const html = readFileSync(file, "utf8");
  const page = { route: routeRelative, file, html, root: parseHtml(html) };
  pageCache.set(routeRelative, page);
  return page;
}

function routeRelativeFromPathname(pathname) {
  if (base !== "/") {
    if (!pathname.startsWith(base)) return undefined;
    return pathname.slice(base.length);
  }
  return pathname.replace(/^\/+/, "");
}

function urlForPage(routeRelative) {
  return new URL(`${base}${routeRelative.replace(/^\/+/, "")}`, "http://site.test");
}

function idsForRoute(routeRelative) {
  const file = resolveDistFile(distDir, routeRelative);
  if (!file || !file.endsWith(".html")) return undefined;
  const key = `ids:${routeRelative}`;
  if (pageCache.has(key)) return pageCache.get(key);
  const ids = new Set();
  for (const element of elements(parseHtml(readFileSync(file, "utf8")))) {
    const id = attr(element, "id");
    if (id) ids.add(id);
    if (element.tag === "a" && attr(element, "name")) ids.add(attr(element, "name"));
  }
  pageCache.set(key, ids);
  return ids;
}

// A published fragment may keep a percent-encoded form (`#a%2Cb`): browsers
// look the raw value up first and only then the decoded one, and the previous
// site published ids that literally contain `%2C`. Both forms are accepted
// here; test/browser.mjs additionally proves navigation really works.
// Dist id counts per route: the published-anchor check needs "exactly one
// element", and the current-source check needs the same set as `idsForRoute`.
const pageIdCache = new Map();

function pageIdIndex(routeRelative, { optional = false } = {}) {
  if (pageIdCache.has(routeRelative)) return pageIdCache.get(routeRelative);
  const file = resolveDistFile(distDir, routeRelative);
  if (!file) {
    assert.ok(optional, `expected a built page for "${base}${routeRelative}"`);
    return undefined;
  }
  const counts = new Map();
  const headingIds = [];
  for (const element of elements(parseHtml(readFileSync(file, "utf8")))) {
    const id = attr(element, "id");
    if (!id) continue;
    counts.set(id, (counts.get(id) ?? 0) + 1);
    if (/^h[1-6]$/.test(element.tag)) headingIds.push(id);
  }
  const index = { ids: new Set(counts.keys()), counts, headingIds };
  pageIdCache.set(routeRelative, index);
  return index;
}

function fragmentTarget(ids, fragment) {
  if (!fragment) return true;
  const raw = fragment.startsWith("#") ? fragment.slice(1) : fragment;
  if (ids.has(raw)) return true;
  try {
    return ids.has(decodeURIComponent(raw));
  } catch {
    return false;
  }
}

const RESOURCE_ATTRIBUTES = [
  ["a", "href"],
  ["link", "href"],
  ["img", "src"],
  ["img", "srcset"],
  ["script", "src"],
  ["source", "src"],
  ["source", "srcset"],
  ["video", "src"],
  ["video", "poster"],
  ["audio", "src"],
  ["object", "data"],
  ["use", "href"],
  ["use", "xlink:href"],
  ["image", "href"],
  ["image", "xlink:href"],
];

function firstSrcsetEntry(value) {
  return value.split(",")[0]?.trim().split(/\s+/)[0] || undefined;
}

function collectReferences(page) {
  const references = [];
  for (const element of elements(page.root)) {
    for (const [tag, attribute] of RESOURCE_ATTRIBUTES) {
      if (element.tag !== tag) continue;
      const raw = attr(element, attribute);
      if (raw === undefined || raw.trim() === "") continue;
      const value = attribute.endsWith("srcset") ? firstSrcsetEntry(raw) : raw.trim();
      if (value) references.push({ element, attribute, raw: value });
    }
  }
  return references;
}

function analyzeReferences(page) {
  const origin = urlForPage(page.route).origin;
  const ownIds = idsForRoute(page.route) ?? new Set();
  const internal = [];
  const external = [];
  const problems = [];
  for (const reference of collectReferences(page)) {
    let resolved;
    try {
      resolved = new URL(reference.raw, urlForPage(page.route));
    } catch {
      problems.push(`unparsable ${reference.attribute}="${reference.raw}"`);
      continue;
    }
    if (resolved.protocol !== "http:" && resolved.protocol !== "https:") continue;
    if (resolved.origin !== origin) {
      external.push(resolved.href);
      continue;
    }
    let pathname;
    try {
      pathname = decodeURIComponent(resolved.pathname);
    } catch {
      problems.push(`undecodable path in ${reference.attribute}="${reference.raw}"`);
      continue;
    }
    const routeRelative = routeRelativeFromPathname(pathname);
    if (routeRelative === undefined) {
      problems.push(`"${reference.raw}" resolves to ${resolved.pathname}, outside base "${base}"`);
      continue;
    }
    const target = resolveDistFile(distDir, routeRelative);
    if (!target) {
      problems.push(
        `"${reference.raw}" resolves to ${resolved.pathname} but no file exists in dist`,
      );
      continue;
    }
    if (resolved.hash) {
      const ids = routeRelative === page.route ? ownIds : idsForRoute(routeRelative);
      if (ids && !fragmentTarget(ids, resolved.hash)) {
        problems.push(
          `"${reference.raw}" points at ${resolved.hash}, which does not exist in ${resolved.pathname}`,
        );
      }
    }
    internal.push({
      raw: reference.raw,
      pathname: resolved.pathname,
      file: target,
      fragment: resolved.hash,
    });
  }
  return { internal, external, problems };
}

// ---------------------------------------------------------------------------
// Rendering comparisons
// ---------------------------------------------------------------------------

function normalizeRenderedCode(text) {
  const lines = text
    .replace(/\u00a0/g, " ")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/, ""));
  while (lines.length && lines[0].trim() === "") lines.shift();
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  return lines.join("\n");
}

function stripLineNumberPrefix(text) {
  return text
    .split("\n")
    .map((line) => line.replace(/^\s*\d{1,4}\s?[.:|]?\s?/, ""))
    .join("\n");
}

function collapseIndentation(text) {
  return text
    .split("\n")
    .map((line) => line.replace(/^[ \t]+/, ""))
    .join("\n");
}

function renderedCodeBlocks(page) {
  const blocks = [];
  for (const pre of elementsByTag(page.root, "pre")) {
    const code = elementsByTag(pre, "code");
    const texts = [];
    if (code.length) texts.push(normalizeRenderedCode(pageText(code[0], { skip: new Set() })));
    texts.push(normalizeRenderedCode(pageText(pre, { skip: new Set(["script", "style"]) })));
    blocks.push({ element: pre, texts: texts.filter(Boolean) });
  }
  return blocks;
}

// Match every Markdown fence against the rendered HTML, in order. Extra
// rendered blocks (for example a layout sample) are recorded, not failed.
function matchCodeBlocks(page, sourceBlocks) {
  const rendered = renderedCodeBlocks(page);
  const result = {
    matched: [],
    missing: [],
    indentationOnly: [],
    extraBeforeMatch: 0,
    usedLineNumberFallback: false,
  };
  let cursor = 0;
  for (const source of sourceBlocks) {
    const wanted = normalizeRenderedCode(source.code);
    let matchIndex = -1;
    for (let index = cursor; index < rendered.length; index += 1) {
      if (rendered[index].texts.includes(wanted)) {
        matchIndex = index;
        break;
      }
    }
    if (matchIndex === -1) {
      const withoutNumbers = stripLineNumberPrefix(wanted);
      for (let index = cursor; index < rendered.length; index += 1) {
        if (rendered[index].texts.some((text) => stripLineNumberPrefix(text) === withoutNumbers)) {
          matchIndex = index;
          result.usedLineNumberFallback = true;
          break;
        }
      }
    }
    if (matchIndex === -1) {
      // Last resort: a renderer may only have shifted indentation (for example
      // inside a nested list). That is a formatting difference, not missing
      // code, so record it separately instead of reporting lost content.
      const flattened = collapseIndentation(wanted);
      for (let index = cursor; index < rendered.length; index += 1) {
        if (rendered[index].texts.some((text) => collapseIndentation(text) === flattened)) {
          matchIndex = index;
          result.indentationOnly.push(source);
          break;
        }
      }
    }
    if (matchIndex === -1) {
      result.missing.push(source);
      continue;
    }
    if (matchIndex > cursor) result.extraBeforeMatch += matchIndex - cursor;
    cursor = matchIndex + 1;
    result.matched.push({ source });
  }
  return result;
}

function describeCodeBlock(block) {
  const firstLine = block.code.split("\n")[0] ?? "";
  return `lang=${block.lang || "text"} first line ${JSON.stringify(firstLine.slice(0, 70))}`;
}

function matchProseBlocks(renderedText, sourceBlocks) {
  const haystack = normalizeForCompare(renderedText);
  const missing = [];
  const skippedShort = [];
  for (const block of sourceBlocks) {
    const wanted = normalizeForCompare(block.text);
    if (block.text.length < 8) {
      if (!haystack.includes(wanted)) skippedShort.push(block.text);
      continue;
    }
    if (!haystack.includes(wanted)) missing.push(block.text);
  }
  return { missing, skippedShort };
}

// ---------------------------------------------------------------------------
// Shared page assertions
// ---------------------------------------------------------------------------

function pageProblems(routeRelative) {
  const page = loadPage(routeRelative);
  const problems = [];
  const htmlElement = elementsByTag(page.root, "html")[0];
  if (!htmlElement) problems.push("missing <html> element");
  else if (!(attr(htmlElement, "lang") ?? "").toLowerCase().startsWith("en")) {
    problems.push(
      `<html lang> is ${JSON.stringify(attr(htmlElement, "lang"))}, expected an English locale`,
    );
  }
  const mains = elements(page.root).filter(isMainLandmark);
  if (mains.length !== 1) problems.push(`expected exactly 1 main landmark, found ${mains.length}`);
  const headings = elementsByTag(page.root, "h1");
  if (headings.length !== 1) problems.push(`expected exactly 1 <h1>, found ${headings.length}`);
  if (
    !elements(page.root).some(
      (element) => element.tag === "meta" && attr(element, "name") === "viewport",
    )
  ) {
    problems.push('missing <meta name="viewport">');
  }
  return { page, problems, main: mains[0], h1: headings[0] };
}

function metaContent(page, name) {
  const meta = elements(page.root).find(
    (element) => element.tag === "meta" && attr(element, "name")?.toLowerCase() === name,
  );
  return meta ? (attr(meta, "content") ?? "") : undefined;
}

function canonicalHref(page) {
  const link = elements(page.root).find((element) => {
    if (element.tag !== "link") return false;
    return (attr(element, "rel") ?? "").toLowerCase().split(/\s+/).includes("canonical");
  });
  return link ? attr(link, "href") : undefined;
}

function checkMetadata(page, expectedTitle) {
  const problems = [];
  const title = elementsByTag(page.root, "title")[0];
  const titleText = title ? collapseWhitespace(pageText(title, { skip: new Set() })) : "";
  if (!titleText) problems.push("missing <title>");
  else if (!titleText.includes(expectedTitle)) {
    problems.push(
      `<title> ${JSON.stringify(titleText)} does not contain ${JSON.stringify(expectedTitle)}`,
    );
  }

  const description = metaContent(page, "description");
  if (!description) problems.push('missing <meta name="description">');
  else if (description.trim().length < 40) {
    problems.push(`description is too short to be route-specific: ${JSON.stringify(description)}`);
  }

  const canonical = canonicalHref(page);
  if (!canonical) problems.push('missing <link rel="canonical">');
  else {
    const resolved = new URL(canonical, urlForPage(page.route));
    const routeRelative = routeRelativeFromPathname(resolved.pathname);
    if (routeRelative === undefined) {
      problems.push(`canonical ${JSON.stringify(canonical)} is outside base "${base}"`);
    } else {
      const normalise = (value) => value.replace(/\/+$/, "");
      const aliases = page.topicId ? (routesForTopic(page.topicId).acceptedAliases ?? []) : [];
      const acceptable = new Set([normalise(page.route), ...aliases.map(normalise)]);
      if (!acceptable.has(normalise(routeRelative))) {
        problems.push(
          `canonical ${JSON.stringify(canonical)} resolves to "${routeRelative}", expected "${page.route}"`,
        );
      }
    }
  }

  const iconLinks = elements(page.root).filter((element) => {
    if (element.tag !== "link") return false;
    return (attr(element, "rel") ?? "").toLowerCase().split(/\s+/).includes("icon");
  });
  if (!iconLinks.length) problems.push('missing <link rel="icon">');
  const appleLinks = elements(page.root).filter(
    (element) =>
      element.tag === "link" &&
      (attr(element, "rel") ?? "").toLowerCase().includes("apple-touch-icon"),
  );
  if (!appleLinks.length) problems.push('missing <link rel="apple-touch-icon">');
  for (const link of [...iconLinks, ...appleLinks]) {
    const href = attr(link, "href");
    if (!href) {
      problems.push(`favicon link without href: ${JSON.stringify(link.attrs)}`);
      continue;
    }
    const resolved = new URL(href, urlForPage(page.route));
    const routeRelative = routeRelativeFromPathname(resolved.pathname);
    if (routeRelative === undefined || !resolveDistFile(distDir, routeRelative)) {
      problems.push(`favicon ${JSON.stringify(href)} does not resolve inside dist`);
    }
  }
  return { problems, titleText, description, canonical };
}

function checkPlaceholders(page) {
  const problems = [];
  const prose = proseText(page.root);
  for (const { name, pattern } of FORBIDDEN_PROSE_PATTERNS) {
    const match = pattern.exec(prose);
    if (match) problems.push(`${name} found in rendered prose: ${JSON.stringify(match[0])}`);
  }
  const rawToken = /%[A-Z][A-Z0-9_]{2,}%/.exec(page.html);
  if (rawToken)
    problems.push(`unresolved build token in HTML output: ${JSON.stringify(rawToken[0])}`);
  return problems;
}

function findNavigation(root, name) {
  return navigationElements(root).filter((element) => accessibleName(element) === name);
}

function navigationLabelInventory(root) {
  return navigationElements(root).map(
    (element) => accessibleName(element) || `(unnamed nav #${attr(element, "id") ?? "?"})`,
  );
}

function checkApiSectionsNavigation(page) {
  const problems = [];
  const navs = findNavigation(page.root, NAV_NAMES.apiSections);
  if (!navs.length) {
    return {
      problems: [
        `no <nav> named ${JSON.stringify(NAV_NAMES.apiSections)} (found: ${JSON.stringify(navigationLabelInventory(page.root))})`,
      ],
      navs,
    };
  }
  const expectedRoutes = TOPIC_IDS.map((id) => routesForTopic(id));
  for (const nav of navs) {
    const links = linkElements(nav);
    const apiLinks = links.filter((link) => {
      const resolved = new URL(attr(link, "href"), urlForPage(page.route));
      const relative = routeRelativeFromPathname(resolved.pathname);
      return relative !== undefined && relative.replace(/\/+$/, "").startsWith("api");
    });
    const outsideBase = [];
    const routeKeys = apiLinks.map((link) => {
      const resolved = new URL(attr(link, "href"), urlForPage(page.route));
      const relative = routeRelativeFromPathname(resolved.pathname);
      if (relative === undefined) {
        outsideBase.push(`${attr(link, "href")} → ${resolved.pathname}`);
        return `outside-base:${resolved.pathname}`;
      }
      return relative.replace(/\/+$/, "");
    });
    for (const entry of outsideBase) {
      problems.push(`nav link ${entry} resolves outside the deployment base "${base}"`);
    }
    const acceptable = expectedRoutes.map(
      (entry) =>
        new Set([entry.route, ...entry.acceptedAliases].map((value) => value.replace(/\/+$/, ""))),
    );
    if (routeKeys.length !== expectedRoutes.length) {
      problems.push(
        `nav "${NAV_NAMES.apiSections}" lists ${routeKeys.length} API links, expected ${expectedRoutes.length}: ${JSON.stringify(routeKeys)}`,
      );
    }
    for (let index = 0; index < Math.min(routeKeys.length, acceptable.length); index += 1) {
      if (!acceptable[index].has(routeKeys[index])) {
        problems.push(
          `nav link #${index + 1} points at "${routeKeys[index]}", expected one of ${JSON.stringify([...acceptable[index]])}`,
        );
      }
    }
    const currentLinks = links.filter((link) => {
      const value = attr(link, "aria-current");
      return value !== undefined && value !== "false";
    });
    if (currentLinks.length !== 1) {
      problems.push(
        `nav "${NAV_NAMES.apiSections}" marks ${currentLinks.length} links with aria-current, expected 1`,
      );
    } else {
      const resolved = new URL(attr(currentLinks[0], "href"), urlForPage(page.route));
      const routeRelative = routeRelativeFromPathname(resolved.pathname);
      const topicRoutes = routesForTopic(page.topicId ?? "");
      const expected = topicRoutes.route.replace(/\/+$/, "");
      const aliases = topicRoutes.acceptedAliases.map((value) => value.replace(/\/+$/, ""));
      if (routeRelative === undefined) {
        problems.push(
          `aria-current link ${attr(currentLinks[0], "href")} resolves to ${resolved.pathname}, outside base "${base}"`,
        );
      } else if (![expected, ...aliases].includes(routeRelative.replace(/\/+$/, ""))) {
        problems.push(
          `aria-current points at "${routeRelative}", expected "${expected}" for route "${page.route}"`,
        );
      }
    }
    const navText = collapseWhitespace(pageText(nav, { skip: new Set(["script", "style"]) }));
    let searchFrom = 0;
    for (const group of GROUP_ORDER) {
      const found = navText.indexOf(group, searchFrom);
      if (found === -1) {
        problems.push(`nav no longer shows the group heading ${JSON.stringify(group)} in order`);
        break;
      }
      searchFrom = found + group.length;
    }
  }
  return { problems, navs };
}

function checkPager(page) {
  const problems = [];
  const navs = findNavigation(page.root, NAV_NAMES.documentPager);
  if (!navs.length) {
    return {
      problems: [
        `no <nav> named ${JSON.stringify(NAV_NAMES.documentPager)} (found: ${JSON.stringify(navigationLabelInventory(page.root))})`,
      ],
    };
  }
  const previous = previousTopic(page.topicId);
  const next = nextTopic(page.topicId);
  const expected = [];
  if (previous) expected.push({ topic: previous, position: "previous" });
  if (next) expected.push({ topic: next, position: "next" });
  for (const nav of navs) {
    // A disabled neighbour may be rendered as an inert link; only real
    // navigation entries count.
    const links = linkElements(nav).filter((link) => {
      if ((attr(link, "aria-disabled") ?? "") === "true") return false;
      const href = (attr(link, "href") ?? "").trim();
      return href !== "" && href !== "#";
    });
    if (links.length !== expected.length) {
      problems.push(
        `pager has ${links.length} links, expected ${expected.length} (${expected.map((entry) => entry.topic.id).join(", ") || "none"})`,
      );
    }
    for (let index = 0; index < Math.min(links.length, expected.length); index += 1) {
      const resolved = new URL(attr(links[index], "href"), urlForPage(page.route));
      const routeRelative = routeRelativeFromPathname(resolved.pathname);
      if (routeRelative === undefined) {
        problems.push(
          `pager link #${index + 1} points at ${attr(links[index], "href")} (${resolved.pathname}), outside base "${base}"`,
        );
        continue;
      }
      const topicRoutes = routesForTopic(expected[index].topic.id);
      const wanted = [topicRoutes.route, ...topicRoutes.acceptedAliases].map((value) =>
        value.replace(/\/+$/, ""),
      );
      if (!wanted.includes(routeRelative.replace(/\/+$/, ""))) {
        problems.push(
          `pager link #${index + 1} (${expected[index].position}) points at "${routeRelative}", expected one of ${JSON.stringify(wanted)}`,
        );
        continue;
      }
      const text = collapseWhitespace(
        pageText(links[index], { skip: new Set(["script", "style"]) }),
      );
      const title = docsById.get(expected[index].topic.id)?.title ?? expected[index].topic.navTitle;
      const acceptedTitles =
        expected[index].topic.id === "overview" ? [title, "Overview"] : [title];
      if (!acceptedTitles.some((candidate) => text.includes(candidate))) {
        problems.push(
          `pager link #${index + 1} text ${JSON.stringify(text)} does not name ${JSON.stringify(title)}`,
        );
      }
      const label = `${text} ${attr(links[index], "aria-label") ?? ""}`;
      if (expected[index].position === "previous" && !/prev/i.test(label)) {
        problems.push(
          `pager link #${index + 1} lost its "Previous" wording: ${JSON.stringify(text)}`,
        );
      }
      if (expected[index].position === "next" && !/next/i.test(label)) {
        problems.push(`pager link #${index + 1} lost its "Next" wording: ${JSON.stringify(text)}`);
      }
    }
  }
  return { problems };
}

function isVisibleInStaticHtml(element) {
  if (attr(element, "hidden") !== undefined) return false;
  if ((attr(element, "aria-hidden") ?? "") === "true") return false;
  return true;
}

function checkTableOfContents(page, doc) {
  const problems = [];
  const headings = doc.headings.filter((heading) => heading.depth === 2 || heading.depth === 3);
  const navs = findNavigation(page.root, NAV_NAMES.tableOfContents);
  if (!navs.length) {
    if (headings.length) {
      problems.push(
        `no <nav> named ${JSON.stringify(NAV_NAMES.tableOfContents)} (found: ${JSON.stringify(navigationLabelInventory(page.root))})`,
      );
    }
    return { problems, tocLinks: 0 };
  }
  const nav = navs[0];
  const links = linkElements(nav).filter(isVisibleInStaticHtml);
  const texts = links.map((link) =>
    collapseWhitespace(pageText(link, { skip: new Set(["script", "style"]) })),
  );
  const docHeadingTexts = new Set(doc.headings.map((heading) => normalizeForCompare(heading.text)));
  for (const text of texts) {
    if (docHeadingTexts.has(normalizeForCompare(text))) continue;
    if (/^(back to top|top)$/i.test(text)) continue;
    problems.push(
      `table of contents links ${JSON.stringify(text)}, which is not a heading in ${doc.fileName}`,
    );
  }
  let cursor = 0;
  for (const heading of headings) {
    const wanted = normalizeForCompare(heading.text);
    const index = texts.findIndex(
      (text, position) => position >= cursor && normalizeForCompare(text) === wanted,
    );
    if (index === -1) {
      problems.push(
        `table of contents is missing or reorders the heading ${JSON.stringify(heading.text)} (h${heading.depth})`,
      );
      continue;
    }
    cursor = index + 1;
  }
  const ownIds = idsForRoute(page.route) ?? new Set();
  for (const link of links) {
    const href = attr(link, "href") ?? "";
    if (!href.startsWith("#")) {
      problems.push(`table of contents entry ${JSON.stringify(href)} is not a same-page fragment`);
      continue;
    }
    if (!fragmentTarget(ownIds, href)) {
      problems.push(`table of contents entry ${JSON.stringify(href)} has no matching element id`);
    }
  }
  return { problems, tocLinks: links.length };
}

function checkClientRuntime(page) {
  const problems = [];
  const scriptElements = elementsByTag(page.root, "script");
  let totalBytes = 0;
  for (const script of scriptElements) {
    const src = attr(script, "src");
    if (src) {
      const resolved = new URL(src, urlForPage(page.route));
      const relative = routeRelativeFromPathname(resolved.pathname);
      const file = relative === undefined ? undefined : resolveDistFile(distDir, relative);
      if (file) totalBytes += fileBytes(file);
    } else {
      totalBytes += Buffer.byteLength(pageText(script, { skip: new Set() }), "utf8");
    }
  }
  for (const link of elements(page.root)) {
    if (link.tag !== "link") continue;
    const rels = (attr(link, "rel") ?? "").toLowerCase().split(/\s+/);
    const isScriptPreload =
      rels.includes("modulepreload") ||
      (rels.includes("preload") && (attr(link, "as") ?? "") === "script");
    if (!isScriptPreload) continue;
    const resolved = new URL(attr(link, "href") ?? "", urlForPage(page.route));
    const relative = routeRelativeFromPathname(resolved.pathname);
    const file = relative === undefined ? undefined : resolveDistFile(distDir, relative);
    if (file) totalBytes += fileBytes(file);
  }
  if (/<astro-island[\s>]/.test(page.html))
    problems.push("<astro-island> custom element present in the markup");
  if (/\sclient:[a-z-]+=/.test(page.html))
    problems.push("Astro client:* hydration directive present in the markup");
  if (scriptElements.length > MAX_PAGE_SCRIPT_ELEMENTS) {
    problems.push(
      `${scriptElements.length} script elements, budget is ${MAX_PAGE_SCRIPT_ELEMENTS}`,
    );
  }
  if (totalBytes > MAX_PAGE_JS_BYTES) {
    problems.push(
      `page ships ${totalBytes} bytes of JavaScript, budget is ${MAX_PAGE_JS_BYTES} (documentation pages must not load a full app bundle)`,
    );
  }
  for (const script of scriptElements) {
    const src = attr(script, "src") ?? "";
    if (/react|astro-island|hydrat/i.test(src))
      problems.push(`framework runtime script referenced: ${src}`);
    const inline = pageText(script, { skip: new Set() });
    if (/astro-island|react-dom/i.test(inline))
      problems.push("framework runtime code found inline in a script tag");
  }
  return { problems, scriptElements: scriptElements.length, totalBytes };
}

function collectJsAssets(directory) {
  const found = [];
  const visit = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (/\.m?js$/.test(entry.name)) found.push(full);
    }
  };
  visit(directory);
  return found;
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

// The asset prefix a dist was built with ("/" or "/repo/"), read from the
// references Astro emitted. A mismatch with SITE_BASE_PATH would fail every
// other check, so it aborts the run once with a clear message.
function detectBuiltBase() {
  const page = loadPage("");
  const patterns = ["_astro/", "logo/", "assets/"];
  const seen = new Set();
  for (const element of elements(page.root)) {
    const value = attr(element, "href") ?? attr(element, "src");
    if (!value || /^[a-z]+:|^#|^\/\//i.test(value)) continue;
    for (const marker of patterns) {
      const index = value.indexOf(marker);
      if (index === -1) continue;
      seen.add(value.slice(0, index));
      break;
    }
  }
  assert.ok(seen.size, "no base-relative asset references found on the home page");
  assert.equal(seen.size, 1, `home page mixes asset prefixes ${JSON.stringify([...seen])}`);
  return [...seen][0];
}

before(() => {
  requireDist();
  const builtBase = detectBuiltBase();
  metrics.builtBase = builtBase;
  assert.equal(
    builtBase,
    base,
    `dist assets are prefixed with ${JSON.stringify(builtBase)} but the tests are configured for ` +
      `${JSON.stringify(base)}; rebuild with SITE_BASE_PATH=${JSON.stringify(builtBase)} or set SITE_BASE_PATH to match`,
  );
});

after(() => {
  try {
    mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, "static-metrics.json");
    writeFileSync(reportPath, `${JSON.stringify(metrics, null, 2)}\n`);
    console.log(`[static.test] metrics written to ${reportPath}`);
  } catch (error) {
    console.warn(`[static.test] could not write metrics: ${error.message}`);
  }
});

describe("build configuration", () => {
  it("dist was built for the configured base path", () => {
    assert.equal(detectBuiltBase(), base, `configured base is ${JSON.stringify(base)}`);
    return `base ${base}`;
  });

  it("resolves the canonical content sources", () => {
    assert.deepEqual(
      docs.map((doc) => doc.id),
      TOPIC_IDS,
    );
    for (const doc of docs)
      assert.ok(doc.frontmatter.title, `${doc.fileName} has no frontmatter title`);
    assert.equal(snippets.length, 4);
    for (const snippet of snippets)
      assert.ok(snippet.codeBlocks.length, `${snippet.file} has no code block`);
  });
});

describe("home page", () => {
  const route = "";

  it("renders one H1, the hero copy and a single main landmark", () => {
    const { page, problems, main, h1 } = pageProblems(route);
    assert.deepEqual(problems, []);
    assert.ok(main, "home page has no main landmark");
    assert.equal(collapseWhitespace(pageText(h1, { skip: new Set() })), "zig-napi");
    metrics.pages.home = { file: page.file };
  });

  it("preserves every home page copy string", () => {
    const { page } = pageProblems(route);
    // Copy lives both inside and outside <main> (header, footer), so the
    // whole rendered document is the haystack here.
    const text = pageText(page.root, { skip: new Set() });
    const missing = HOME_REQUIRED_COPY.filter((copy) => !containsText(text, copy));
    assert.deepEqual(missing, [], `home page copy missing:\n- ${missing.join("\n- ")}`);
    const missingPatterns = HOME_REQUIRED_PATTERNS.filter(
      (entry) => !entry.pattern.test(normalizeForCompare(text)),
    );
    assert.deepEqual(
      missingPatterns.map((entry) => entry.expected),
      [],
      "home page copy missing",
    );
  });

  it("keeps the section order", () => {
    const { page } = pageProblems(route);
    const text = normalizeForCompare(pageText(page.root, { skip: new Set() }));
    let cursor = 0;
    const outOfOrder = [];
    for (const section of HOME_SECTION_ORDER) {
      const index = text.indexOf(normalizeForCompare(section), cursor);
      if (index === -1) outOfOrder.push(section);
      else cursor = index + section.length;
    }
    assert.deepEqual(
      outOfOrder,
      [],
      `home page sections missing or reordered:\n- ${outOfOrder.join("\n- ")}`,
    );
  });

  it("keeps the home page anchors and project assets", () => {
    const page = loadPage(route);
    const ids = new Set(
      elements(page.root)
        .map((element) => attr(element, "id"))
        .filter(Boolean),
    );
    const missing = HOME_REQUIRED_ANCHORS.filter((anchor) => !ids.has(anchor));
    assert.deepEqual(missing, [], `home page anchors missing: ${missing.join(", ")}`);
    const text = pageText(page.root, { skip: new Set(["script", "style"]) });
    for (const label of HOME_NAV_LABELS) {
      assert.ok(containsText(text, label), `home page lost the ${JSON.stringify(label)} link`);
    }
    const links = elements(page.root).filter(
      (element) => element.tag === "a" && attr(element, "href") === GITHUB_URL,
    );
    assert.ok(links.length >= 1, `no link to ${GITHUB_URL}`);
    const sources = elements(page.root).map((element) => attr(element, "src") ?? "");
    for (const asset of HOME_ASSETS) {
      assert.ok(
        sources.some((source) => source.endsWith(asset)),
        `home page no longer references ${asset}`,
      );
    }
    // The retired pipeline bitmap is not fetched by anything on the page.
    const retired = elements(page.root).flatMap((element) =>
      Object.entries(element.attrs ?? {})
        .filter(([, value]) => value.includes(PIPELINE.retiredImage))
        .map(([name, value]) => `${element.tag}[${name}="${value}"]`),
    );
    assert.deepEqual(
      retired,
      [],
      `home page still references the retired pipeline bitmap ${PIPELINE.retiredImage}`,
    );
    metrics.homeAnchors = {
      present: HOME_REQUIRED_ANCHORS.filter((anchor) => ids.has(anchor)),
      optional: HOME_OPTIONAL_ANCHORS.filter((anchor) => ids.has(anchor)),
    };
  });

  it("renders the build pipeline as an overview figure with real guide links", () => {
    const page = loadPage(route);
    const figure = elements(page.root).find(
      (element) => attr(element, "id") === PIPELINE.figureId,
    );
    assert.ok(
      figure,
      `home page has no #${PIPELINE.figureId} figure to read the build pipeline from`,
    );

    // Native HTML on purpose: no bitmap or inline SVG to shrink on a phone and
    // no script to run. The figure has to stay readable as text.
    const media = elements(figure)
      .map((element) => element.tag)
      .filter((tag) => ["img", "svg", "picture", "canvas", "script", "iframe"].includes(tag));
    assert.deepEqual(
      media,
      [],
      `the pipeline figure must stay semantic HTML, found: ${JSON.stringify(media)}`,
    );

    const text = collapseWhitespace(pageText(figure, { skip: new Set(["script", "style"]) }));
    const missing = PIPELINE.labels.filter((label) => !containsText(text, label));
    assert.deepEqual(missing, [], `pipeline labels missing:\n- ${missing.join("\n- ")}`);

    // An overview, not a tutorial: command lines, flags and runtime plugin
    // behavior belong to the guides the figure links to.
    const leaked = PIPELINE.deferredToGuides.filter((entry) => entry.pattern.test(text));
    assert.deepEqual(
      leaked.map((entry) => entry.expected),
      [],
      "the pipeline figure carries detail that belongs to the guides it links to",
    );

    // Every node links to the guide that owns its detail, resolved against the
    // deployment base rather than hard-coded.
    const anchors = linkElements(figure);
    const problems = [];
    for (const guide of PIPELINE.guides) {
      const expectedPath = `${base}${routesForTopic(guide.topic).route}`;
      const match = anchors.find((anchor) => {
        const href = attr(anchor, "href") ?? "";
        const resolved = new URL(href, urlForPage(route));
        if (resolved.pathname !== expectedPath) return false;
        const label = collapseWhitespace(pageText(anchor, { skip: new Set() }));
        return containsText(label, guide.label);
      });
      if (!match) {
        problems.push(
          `no link to ${expectedPath} labelled ${JSON.stringify(guide.label)}; ` +
            `found ${JSON.stringify(anchors.map((anchor) => attr(anchor, "href")))}`,
        );
      }
    }
    assert.deepEqual(problems, []);
    assert.ok(
      anchors.length >= PIPELINE.guides.length,
      `pipeline figure has ${anchors.length} links, expected at least ${PIPELINE.guides.length}`,
    );
    metrics.pipeline = {
      figureId: PIPELINE.figureId,
      labels: PIPELINE.labels.length,
      links: anchors.length,
      guides: PIPELINE.guides.map((guide) => guide.topic),
    };
  });

  it("keeps all four build recipes in the initial HTML", () => {
    const page = loadPage(route);
    for (const snippet of snippets) {
      const result = matchCodeBlocks(page, snippet.codeBlocks);
      assert.deepEqual(
        result.missing.map(describeCodeBlock),
        [],
        `snippet ${snippet.label} (${snippet.file}) is not rendered in the static HTML`,
      );
    }
  });

  it("renders the build recipes as readable linked panels without JavaScript", () => {
    // Progressive enhancement: the initial HTML is four anchor links and four
    // visible snippets. The ARIA tab widget (roles, one selected tab, roving
    // tabindex) only has to exist once the script has run, which is verified in
    // test/browser.mjs.
    const page = loadPage(route);
    const strips = elements(page.root).filter(
      (element) => accessibleName(element) === "Build recipe snippets",
    );
    assert.equal(
      strips.length,
      1,
      `expected one element named "Build recipe snippets", found ${strips.length}`,
    );
    const anchors = linkElements(strips[0]);
    assert.deepEqual(
      anchors.map((anchor) => collapseWhitespace(pageText(anchor, { skip: new Set() }))),
      snippets.map((snippet) => snippet.label),
      "the build recipe switcher no longer lists the four recipes in order",
    );
    let linked = 0;
    for (let index = 0; index < snippets.length; index += 1) {
      const snippet = snippets[index];
      const anchor = anchors[index];
      const targetId =
        attr(anchor, "aria-controls") ?? (attr(anchor, "href") ?? "").replace(/^#/, "");
      const target = elements(page.root).find((element) => attr(element, "id") === targetId);
      assert.ok(
        target,
        `${JSON.stringify(snippet.label)} points at "${targetId}", which does not exist`,
      );
      const code = elementsByTag(target, "pre")
        .map((pre) => normalizeRenderedCode(pageText(pre, { skip: new Set(["script", "style"]) })))
        .join("\n");
      assert.ok(
        code.includes(normalizeRenderedCode(snippet.code)),
        `the panel linked from ${JSON.stringify(snippet.label)} does not contain that recipe`,
      );
      linked += 1;
    }
    assert.equal(
      linked,
      snippets.length,
      `only ${linked} of ${snippets.length} recipes link to their panel`,
    );
    metrics.homeTabs = { mode: "linked-panels", tabs: anchors.length };
  });

  it("keeps the sample placeholders inside code and nothing else", () => {
    const page = loadPage(route);
    const codeText = collapseWhitespace(
      elementsByTag(page.root, "pre")
        .map((pre) => pageText(pre, { skip: new Set() }))
        .join("\n"),
    );
    for (const placeholder of EXPECTED_CODE_PLACEHOLDERS) {
      assert.ok(
        codeText.includes(placeholder),
        `build recipe sample placeholder ${JSON.stringify(placeholder)} disappeared from the rendered code`,
      );
    }
    assert.deepEqual(checkPlaceholders(page), []);
  });

  it("has no client-side doc runtime and stays inside the JS budget", () => {
    const page = loadPage(route);
    const result = checkClientRuntime(page);
    assert.deepEqual(result.problems, []);
    metrics.pages.home = {
      ...metrics.pages.home,
      scripts: result.scriptElements,
      jsBytes: result.totalBytes,
    };
  });

  it("resolves every local reference", () => {
    const page = loadPage(route);
    const { problems, internal, external } = analyzeReferences(page);
    assert.deepEqual(problems, []);
    assert.ok(internal.length > 0, "home page has no internal references at all");
    metrics.pages.home = {
      ...metrics.pages.home,
      internalLinks: internal.length,
      externalLinks: external.length,
    };
  });
});

describe("API documentation pages", () => {
  for (const doc of docs) {
    const { route } = routesForTopic(doc.id);

    describe(`${doc.id} (${base}${route})`, () => {
      it("renders the complete Markdown body in the initial HTML", () => {
        const loaded = loadPage(route);
        loaded.topicId = doc.id;
        const { problems, main } = pageProblems(route);
        assert.deepEqual(problems, []);
        assert.ok(main, "no main landmark to check the documentation body in");

        const codeResult = matchCodeBlocks(loaded, doc.codeBlocks);
        assert.deepEqual(
          codeResult.missing.map(describeCodeBlock),
          [],
          `code fences missing from ${doc.fileName}`,
        );
        const prose = matchProseBlocks(pageText(main, { skip: new Set() }), doc.blocks);
        assert.deepEqual(
          prose.missing,
          [],
          `text missing from the rendered page (${doc.fileName})`,
        );

        const shortTotal = doc.blocks.filter((block) => block.text.length < 8).length;
        metrics.pages[doc.id] = {
          file: loaded.file,
          codeBlocks: doc.codeBlocks.length,
          codeBlocksMatched: codeResult.matched.length,
          extraRenderedCodeBlocks: codeResult.extraBeforeMatch,
          lineNumberFallback: codeResult.usedLineNumberFallback,
          indentationOnlyBlocks: codeResult.indentationOnly.length,
          proseBlocks: doc.blocks.length - shortTotal,
          shortBlocksMissing: prose.skippedShort.length,
          shortBlocks: shortTotal,
        };
        metrics.totals.codeBlocks += doc.codeBlocks.length;
        metrics.totals.proseBlocks += doc.blocks.length - shortTotal;
      });

      it("keeps every heading as a linked anchor", () => {
        const loaded = loadPage(route);
        const main = elements(loaded.root).filter(isMainLandmark)[0];
        const rendered = elementsByTag(main ?? loaded.root, ["h2", "h3", "h4"]).map((heading) => ({
          depth: Number(heading.tag.slice(1)),
          text: normalizeForCompare(pageText(heading, { skip: new Set() })),
          id: attr(heading, "id") ?? "",
        }));
        for (const heading of doc.headings.filter((entry) => entry.depth > 1)) {
          const wanted = normalizeForCompare(heading.text);
          const match = rendered.find((entry) => entry.text === wanted);
          assert.ok(
            match,
            `heading ${JSON.stringify(heading.text)} (${doc.fileName}) is missing from the page`,
          );
          assert.ok(match.id, `heading ${JSON.stringify(heading.text)} has no id to link to`);
        }
        const h1 = elementsByTag(loaded.root, "h1")[0];
        assert.ok(h1, "page has no <h1>");
        assert.equal(collapseWhitespace(pageText(h1, { skip: new Set() })), doc.title);
      });

      it("exposes route-specific metadata", () => {
        const loaded = loadPage(route);
        loaded.topicId = doc.id;
        const { problems, titleText, description } = checkMetadata(loaded, doc.title);
        assert.deepEqual(problems, []);
        metrics.pages[doc.id] = { ...metrics.pages[doc.id], title: titleText, description };
      });

      it("keeps the API navigation, pager and table of contents in sync with the route", () => {
        const loaded = loadPage(route);
        loaded.topicId = doc.id;
        const navigation = checkApiSectionsNavigation(loaded);
        const pager = checkPager(loaded);
        const toc = checkTableOfContents(loaded, doc);
        assert.deepEqual(navigation.problems, []);
        assert.deepEqual(pager.problems, []);
        assert.deepEqual(toc.problems, []);
        metrics.pages[doc.id] = {
          ...metrics.pages[doc.id],
          apiNavs: navigation.navs.length,
          tocLinks: toc.tocLinks,
        };
      });

      it("has no template leftovers and no client-side doc runtime", () => {
        const loaded = loadPage(route);
        assert.deepEqual(checkPlaceholders(loaded), []);
        const runtime = checkClientRuntime(loaded);
        assert.deepEqual(runtime.problems, []);
        metrics.pages[doc.id] = {
          ...metrics.pages[doc.id],
          scripts: runtime.scriptElements,
          jsBytes: runtime.totalBytes,
        };
      });

      it("resolves every local reference", () => {
        const loaded = loadPage(route);
        const { problems, internal } = analyzeReferences(loaded);
        assert.deepEqual(problems, []);
        metrics.pages[doc.id] = { ...metrics.pages[doc.id], internalLinks: internal.length };
      });
    });
  }

  it("normalises relative Markdown cross-links to /api/<topic>/ URLs", () => {
    // `conversion-model.md`, `classes-ownership.md` and `callback-functions.md`
    // contain relative links such as `[Ownership](./classes-ownership)`.
    // Rendering must normalise them instead of rewriting the Markdown.
    const problems = [];
    let checked = 0;
    for (const doc of docs) {
      const links = extractRelativeTopicLinks(doc.source ?? "");
      if (!links.length) continue;
      const { route } = routesForTopic(doc.id);
      const page = loadPage(route);
      const anchors = linkElements(page.root).map((element) => ({
        href: attr(element, "href"),
        text: collapseWhitespace(pageText(element, { skip: new Set() })),
      }));
      for (const link of links) {
        checked += 1;
        const target = routesForTopic(link.target).route.replace(/\/+$/, "");
        const match = anchors.find((anchor) => {
          const relative = routeRelativeFromPathname(
            new URL(anchor.href, urlForPage(page.route)).pathname,
          );
          return (
            relative !== undefined &&
            relative.replace(/\/+$/, "") === target &&
            anchor.text.includes(link.label)
          );
        });
        if (!match) {
          problems.push(
            `${doc.fileName}: link [${link.label}](./${link.target}) does not render as an "/api/${link.target}/" anchor with that label`,
          );
        }
      }
    }
    assert.ok(
      checked >= 4,
      `expected relative cross-links in the Markdown sources, found ${checked}`,
    );
    assert.deepEqual(problems, []);
  });
});

describe("published documentation contract", () => {
  it("keeps the original topic routes and the WASM guide that was added to Build", () => {
    // The 15 pre-migration documents keep their ids, their order and their
    // routes; `wasm-runtime` is the added topic and sits in the Build group
    // directly after the Node addon build.
    assert.deepEqual(
      LEGACY_TOPIC_IDS.filter((id) => !TOPIC_IDS.includes(id)),
      [],
      "a pre-migration topic lost its id",
    );
    assert.deepEqual(
      TOPICS.filter((topic) => topic.group === "Build").map((topic) => topic.id),
      ["build-openharmony", "build-node", "wasm-runtime", "declaration-generation"],
      "the Build group no longer reads OpenHarmony, Node, WASM, Declarations",
    );
  });

  it("keeps every heading id the published site exposed", () => {
    // Fixed baseline, not a derivation: `published-anchors.json` holds the 120
    // heading ids a browser render captured from the published pages before the
    // migration. New sections may be appended, but an old heading that is
    // renamed or dropped has to fail here — that is what keeps published
    // fragment URLs working.
    const idsByTopic = new Map();
    for (const topic of Object.keys(PUBLISHED_ANCHORS.topics)) {
      const { ids } = pageIdIndex(routesForTopic(topic).route);
      idsByTopic.set(topic, ids);
    }
    const { checked, problems } = publishedAnchorProblems(PUBLISHED_ANCHORS, idsByTopic);
    assert.equal(
      checked,
      PUBLISHED_ANCHOR_TOTAL,
      `the fixture pins ${PUBLISHED_ANCHOR_TOTAL} heading ids but ${checked} were compared`,
    );
    assert.equal(checked, 120, `the published set is ${checked} heading ids, expected 120`);
    assert.deepEqual(problems, [], `published heading ids missing:\n- ${problems.join("\n- ")}`);

    // One target each, and the published reading order is unchanged.
    const orderProblems = [];
    let ordered = 0;
    for (const [topic, anchors] of Object.entries(PUBLISHED_ANCHORS.topics)) {
      const { counts, headingIds } = pageIdIndex(routesForTopic(topic).route);
      for (const id of anchors) {
        const encoded = encodeURIComponent(id);
        // A published id may be stored encoded; do not count it twice when the
        // two spellings are the same string.
        const matches = (counts.get(id) ?? 0) + (encoded === id ? 0 : (counts.get(encoded) ?? 0));
        if (matches !== 1) {
          orderProblems.push(`${topic}: #${id} matches ${matches} elements, expected exactly 1`);
        }
      }
      const wanted = new Set(anchors.flatMap((id) => [id, encodeURIComponent(id)]));
      const rendered = headingIds.filter((id) => wanted.has(id));
      const expected = anchors.map((id) => (counts.has(id) ? id : encodeURIComponent(id)));
      if (rendered.join("\n") !== expected.join("\n")) {
        orderProblems.push(`${topic}: published heading order changed`);
      } else {
        ordered += rendered.length;
      }
    }
    assert.deepEqual(orderProblems, []);
    metrics.publishedAnchors = {
      checked,
      ordered,
      topics: Object.keys(PUBLISHED_ANCHORS.topics).length,
    };
  });

  it("resolves every heading the current sources publish", () => {
    // The other direction, for new headings: whatever the canonical Markdown
    // says today — appended sections included — must be reachable at its own
    // slug. This derives from the sources, so it can never replace the fixed
    // baseline above.
    const problems = [];
    let checked = 0;
    for (const doc of docs) {
      const { route } = routesForTopic(doc.id);
      const index = pageIdIndex(route, { optional: true });
      if (!index) {
        problems.push(`${doc.id}: no built page at ${base}${route}`);
        continue;
      }
      const { ids } = index;
      const slugs = legacyHeadingSlugs(doc.headings);
      doc.headings.forEach((heading, index) => {
        checked += 1;
        if (!fragmentTarget(ids, `#${slugs[index]}`)) {
          problems.push(`${doc.id}: ${JSON.stringify(heading.text)} -> #${slugs[index]}`);
        }
      });
    }
    assert.ok(checked >= PUBLISHED_ANCHOR_TOTAL, `only ${checked} headings were resolved`);
    assert.deepEqual(problems, [], `heading anchors missing:\n- ${problems.join("\n- ")}`);
    metrics.currentHeadingAnchors = { checked, documents: docs.length };
  });

  it("fails on a renamed published heading even though the page grew (mutation check)", () => {
    // Proof that the fixed baseline can fail: rename one published id in the
    // (in-memory) page ids while keeping the total count — the check reports
    // exactly that heading and nothing else. No production file is touched.
    const idsByTopic = new Map();
    for (const topic of Object.keys(PUBLISHED_ANCHORS.topics)) {
      const { ids } = pageIdIndex(routesForTopic(topic).route);
      idsByTopic.set(topic, ids);
    }
    const [topic, anchors] = Object.entries(PUBLISHED_ANCHORS.topics)[0];
    const renamed = new Set(idsByTopic.get(topic));
    renamed.delete(anchors[0]);
    renamed.add("heading-renamed-in-a-later-revision");
    const mutated = new Map(idsByTopic);
    mutated.set(topic, renamed);
    const { checked, problems } = publishedAnchorProblems(PUBLISHED_ANCHORS, mutated);
    assert.equal(checked, 120, "the mutated input must keep the published count");
    assert.deepEqual(problems, [`${topic}: #${anchors[0]} is missing from the built page`]);

    // And the unmutated input is clean, so the failure above is the rename.
    assert.deepEqual(publishedAnchorProblems(PUBLISHED_ANCHORS, idsByTopic).problems, []);
    metrics.publishedAnchorMutation = { topic, renamedFrom: anchors[0], problems: problems.length };
  });

  it("keeps the key capability of every guide it publishes", () => {
    // Source-level nets over the canonical Markdown: a short factual pattern
    // per capability, so a rewrite cannot silently drop one. Prose stays the
    // writer's; these are the facts the pages exist for.
    const problems = [];
    const checked = [];
    for (const entry of KEY_DOC_FACTS) {
      const doc = docsById.get(entry.id);
      assert.ok(doc, `no canonical document for ${entry.id}`);
      for (const fact of entry.facts) {
        if (!fact.pattern.test(doc.source)) {
          problems.push(`${entry.id}: ${fact.expected}`);
        } else {
          checked.push(`${entry.id}: ${fact.expected}`);
        }
      }
    }
    assert.deepEqual(problems, [], `documented capabilities missing:\n- ${problems.join("\n- ")}`);
    metrics.keyDocFacts = { checked: checked.length, documents: KEY_DOC_FACTS.length };
  });
});

describe("site-wide contract", () => {
describe("Markdown inline parsing (content oracle)", () => {
  // The oracle turns one Markdown fragment into the text a renderer shows. Code
  // spans are literal text, while the emphasis and link syntax around them is
  // still syntax; the old backtick-splitting parser got both wrong at once, so
  // `**`.single` runtime.**` kept its `**` and `` [`Buffer`](#buffer) `` kept
  // its brackets. These cases pin the behaviour, not any particular document.
  const cases = [
    {
      name: "strips emphasis that wraps a code span",
      markdown: "**`.single` runtime.** The body runs on the calling thread.",
      text: ".single runtime. The body runs on the calling thread.",
    },
    {
      name: "strips bold-italic that wraps a code span",
      markdown: "***`both`*** markers",
      text: "both markers",
    },
    {
      name: "keeps the label of a link whose label is a code span",
      markdown: "the fallback note under [`Buffer`](#buffer)), so the",
      text: "the fallback note under Buffer), so the",
    },
    {
      name: "keeps a plain code span verbatim",
      markdown: "Run `napi_build.nodeAddonBuild` once.",
      text: "Run napi_build.nodeAddonBuild once.",
    },
    {
      name: "keeps markdown-looking characters inside code",
      markdown: "`a*b*` and `<T>` and `__init__` and `[x](y)`",
      text: "a*b* and <T> and __init__ and [x](y)",
    },
    {
      name: "strips emphasis around code next to real emphasis",
      markdown: "**imports** its memory (`env.memory`) and **allocates** it",
      text: "imports its memory (env.memory) and allocates it",
    },
    {
      name: "reads a padded span and a span holding a backtick",
      markdown: "Use `` ` `` and `` code `` for quotes.",
      text: "Use ` and code for quotes.",
    },
    {
      name: "leaves an unmatched backtick as ordinary text",
      markdown: "a ` b",
      text: "a ` b",
    },
    {
      name: "drops raw inline HTML and keeps link labels",
      markdown: "<span>plain</span> [label](target) text",
      text: "plain label text",
    },
    {
      name: "keeps entity references literal inside a code span and decodes them outside",
      markdown: "`a&amp;b` and a&amp;b",
      text: "a&amp;b and a&b",
    },
    {
      name: "keeps a backslash literal inside a code span",
      markdown: "`a\\` b",
      text: "a\\ b",
    },
    {
      name: "folds a line ending and drops the padding space inside a code span",
      markdown: "` padded ` and `two\nlines`",
      text: "padded and two lines",
    },
  ];

  for (const entry of cases) {
    it(entry.name, () => {
      assert.equal(
        markdownInlineToText(entry.markdown),
        entry.text,
        `oracle text for ${JSON.stringify(entry.markdown)}`,
      );
    });
  }

  it("still reports prose the page does not contain", () => {
  it("does not let an escaped backtick open a code span", () => {
    // Outside a code span a backslash still escapes, so an escaped backtick is
    // not a delimiter and the emphasis after it stays ordinary syntax. (Turning
    // the escape back into the character it escapes is separate, pre-existing
    // behaviour of this oracle; no published source relies on it.)
    const text = markdownInlineToText("The \\`*not emphasis*\\` tag");
    assert.ok(
      !text.includes("*not emphasis*"),
      `an escaped backtick swallowed the syntax around it: ${JSON.stringify(text)}`,
    );
    assert.ok(text.includes("not emphasis"), JSON.stringify(text));
  });
    // A parser that swallowed everything would pass every prose check; this
    // proves the comparison still fails on text that is really absent, both on
    // a synthetic string and on a block taken from a shipped document.
    const synthetic = matchProseBlocks("<p>the page text</p>", [
      { type: "paragraph", text: "the page text" },
      { type: "paragraph", text: "prose that this page does not contain" },
    ]);
    assert.deepEqual(synthetic.missing, ["prose that this page does not contain"]);

    const doc = docsById.get("binary-data");
    const page = loadPage(routesForTopic(doc.id).route);
    const main = elements(page.root).filter(isMainLandmark)[0];
    const rendered = pageText(main, { skip: new Set() });
    const block = doc.blocks.find((entry) => entry.type === "paragraph" && entry.text.length >= 40);
    assert.ok(block, "binary-data has no paragraph block to probe");
    assert.deepEqual(matchProseBlocks(rendered, [block]).missing, []);
    const tampered = { ...block, text: block.text.replace(/\bthe\b/, "zzzz-not-in-the-page") };
    assert.notEqual(tampered.text, block.text, "the probe did not change the block text");
    assert.deepEqual(
      matchProseBlocks(rendered, [tampered]).missing,
      [tampered.text],
      "a tampered block must still be reported missing",
    );
  });
});

  it("publishes all 17 canonical pages plus a 404 document", () => {
    const routes = ["", ...TOPICS.map((topic) => routesForTopic(topic.id).route)];
    for (const route of routes) {
      const file = resolveDistFile(distDir, route);
      assert.ok(file, `missing page for "${base}${route}"`);
      metrics.totals.pagesChecked += 1;
    }
    assert.ok(
      resolveDistFile(distDir, "404.html"),
      "missing 404.html (unknown routes must not fall back to a page)",
    );
  });

  it("serves /api/overview/ as a page or a base-aware redirect", () => {
    const aliasFile = resolveDistFile(distDir, "api/overview/");
    if (!aliasFile) return;
    const alias = loadPage("api/overview/");
    const refresh = elements(alias.root).find(
      (element) =>
        element.tag === "meta" &&
        (attr(element, "http-equiv") ?? "").toLowerCase() === "refresh" &&
        (attr(element, "content") ?? "").toLowerCase().includes("url="),
    );
    const canonical = canonicalHref(alias);
    const canonicalRelative = canonical
      ? routeRelativeFromPathname(new URL(canonical, urlForPage("api/overview/")).pathname)
      : undefined;
    if (refresh || canonicalRelative === "api/") {
      // A redirect to the canonical page is legitimate; the alias does not have
      // to duplicate the document body.
      const target = refresh
        ? (attr(refresh, "content").match(/url=([^;]+)/i)?.[1] ?? "").trim()
        : canonical;
      const resolved = new URL(target, urlForPage("api/overview/"));
      const relative = routeRelativeFromPathname(resolved.pathname);
      assert.equal(
        relative,
        "api/",
        `overview alias redirects to ${resolved.pathname}, expected ${base}api/`,
      );
      assert.ok(
        resolveDistFile(distDir, relative),
        "overview alias redirect target is not in dist",
      );
      metrics.overviewAlias = { mode: "redirect", target: resolved.pathname };
      return;
    }
    alias.topicId = "overview";
    const { problems, main } = pageProblems("api/overview/");
    assert.deepEqual(problems, []);
    const doc = docsById.get("overview");
    const codeResult = matchCodeBlocks(alias, doc.codeBlocks);
    assert.deepEqual(codeResult.missing.map(describeCodeBlock), []);
    const prose = matchProseBlocks(pageText(main, { skip: new Set() }), doc.blocks);
    assert.deepEqual(prose.missing, []);
    metrics.overviewAlias = { mode: "full-page" };
  });

  it("renders a real 404 document", () => {
    const file = resolveDistFile(distDir, "404.html");
    const html = readFileSync(file, "utf8");
    const page = { route: "404.html", file, html, root: parseHtml(html) };
    const title = elementsByTag(page.root, "title")[0];
    const titleText = title ? collapseWhitespace(pageText(title, { skip: new Set() })) : "";
    assert.ok(titleText, "404 page has no <title>");
    const prose = proseText(page.root);
    assert.ok(
      /(404|not found)/i.test(`${titleText} ${prose}`),
      "404 page does not say the page was not found",
    );
    const { problems, internal } = analyzeReferences(page);
    assert.deepEqual(problems, []);
    assert.ok(internal.length >= 1, "404 page offers no way back into the site");
  });

  it("gives every documentation page a distinct description", () => {
    const descriptions = new Map();
    for (const topic of TOPICS) {
      const route = routesForTopic(topic.id).route;
      const page = loadPage(route);
      page.topicId = topic.id;
      const description = metaContent(page, "description");
      assert.ok(description, `${topic.id} has no meta description`);
      const previous = descriptions.get(description);
      assert.equal(
        previous,
        undefined,
        `${topic.id} and ${previous} share the same meta description`,
      );
      descriptions.set(description, topic.id);
    }
  });

  it("keeps every internal link, fragment and asset resolvable", () => {
    const routes = ["", ...TOPICS.map((topic) => routesForTopic(topic.id).route)];
    const problems = [];
    let internalTotal = 0;
    for (const route of routes) {
      const page = loadPage(route);
      page.topicId = TOPICS.find((topic) => routesForTopic(topic.id).route === route)?.id;
      const { problems: pageIssues, internal } = analyzeReferences(page);
      internalTotal += internal.length;
      for (const issue of pageIssues) problems.push(`${base}${route || ""}: ${issue}`);
    }
    metrics.totals.internalLinks = internalTotal;
    assert.deepEqual(problems, []);
  });

  it("ships no bundle containing the documentation text", () => {
    const samples = distinctiveProseSamples(docs);
    assert.equal(samples.length, TOPICS.length, "content oracle did not produce prose samples");
    const offenders = [];
    for (const file of collectJsAssets(distDir)) {
      const source = readFileSync(file, "utf8");
      for (const sample of samples) {
        if (source.includes(sample.text)) {
          offenders.push(`${path.relative(distDir, file)} contains prose from ${sample.id}`);
          break;
        }
      }
    }
    assert.deepEqual(offenders, [], "documentation text was bundled into JavaScript");
  });

  it("keeps page JavaScript small on every canonical page", () => {
    const routes = ["", ...TOPICS.map((topic) => routesForTopic(topic.id).route)];
    const offenders = [];
    for (const route of routes) {
      const page = loadPage(route);
      const runtime = checkClientRuntime(page);
      if (runtime.problems.length)
        offenders.push(`${base}${route || ""}: ${runtime.problems.join("; ")}`);
    }
    assert.deepEqual(offenders, []);
  });
});
