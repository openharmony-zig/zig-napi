// Real-browser acceptance for the Astro/Kami documentation site.
//
// Run from `website/`:
//
//     node test/browser.mjs
//
// The script starts its own read-only static server for an already built
// `dist/` (it never triggers a build and has no SPA fallback), drives Chromium
// through `playwright-core` and writes screenshots plus a metrics JSON.
//
// Environment (all optional):
//   SITE_BASE_PATH            deployment base (default "/"), also used as the
//                             server prefix
//   WEBSITE_DIST_DIR          dist directory (default "dist")
//   WEBSITE_SCREENSHOT_DIR    screenshot directory (default ".test-results")
//   WEBSITE_TEST_REPORT_DIR   metrics JSON directory (default $TMPDIR/...)
//   CHROME_EXECUTABLE         Chromium/Chrome binary; otherwise the Chromium
//                             installed for playwright-core is used
//   PLAYWRIGHT_MODULE         explicit playwright-core entry point (test override)
//   WEBSITE_BROWSER_DEADLINE_MS
//                             watchdog in milliseconds; may only lower the
//                             default of 180000
//
// Exit codes: 0 = all checks passed, 1 = check failures, 2 = environment
// problem (missing dependency, missing dist, browser that will not start).
// Everything automated is labelled as such: the metrics JSON distinguishes
// machine checks from the screenshots a human still has to look at.

import assert from "node:assert/strict";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  TOPICS,
  collapseWhitespace,
  loadApiDocs,
  loadSnippets,
  resolveDistDir,
  resolveReportDir,
  resolveScreenshotDir,
  routesForTopic,
  siteBasePath,
  trimCode,
} from "./lib/site-contract.mjs";

const DEFAULT_DEADLINE_MS = 180_000;
const configuredDeadline = Number(process.env.WEBSITE_BROWSER_DEADLINE_MS ?? "");
const deadlineMs = Math.min(
  Number.isFinite(configuredDeadline) && configuredDeadline > 0
    ? configuredDeadline
    : DEFAULT_DEADLINE_MS,
  DEFAULT_DEADLINE_MS,
);
const deadlineAt = Date.now() + deadlineMs;

const base = siteBasePath();
const distDir = resolveDistDir();
const screenshotDir = resolveScreenshotDir();
const reportDir = resolveReportDir();
const docs = loadApiDocs();
const docsById = new Map(docs.map((doc) => [doc.id, doc]));
const snippets = loadSnippets();

const DESKTOP = { width: 1280, height: 900 };
const MOBILE = { width: 375, height: 720 };
const NARROW = { width: 320, height: 720 };

const results = [];
const screenshots = [];
const metrics = {
  generatedAt: new Date().toISOString(),
  basePath: base,
  distDir,
  deadlineMs,
  automation: {
    scope: "automated browser checks (layout, semantics, keyboard, clipboard, console errors)",
    note: "visual quality itself is not judged here; screenshots are for the leader's review",
  },
  visualReview: {
    required: true,
    screenshots: [],
    hints: [
      "375px and 1280px first-viewport screenshots for all 16 canonical pages",
      "320px home call-to-action and documentation table screenshots",
      "home #build section, long documentation code block, table and pager regions",
      "compare against the kami landing page tokens (parchment, ink blue, serif body)",
    ],
  },
  routes: {},
  totals: { checks: 0, failures: 0, screenshots: 0, pageLoads: 0 },
};

function record(name, status, details) {
  results.push({ name, status, details });
  metrics.totals.checks += 1;
  if (status === "fail") {
    metrics.totals.failures += 1;
    console.error(`FAIL  ${name}${details ? ` — ${details}` : ""}`);
  } else {
    console.log(`ok    ${name}`);
  }
}

async function check(name, fn) {
  try {
    const details = await fn();
    record(name, "pass", typeof details === "string" ? details : undefined);
    return true;
  } catch (error) {
    record(name, "fail", error?.message ?? String(error));
    return false;
  }
}

class EnvironmentProblem extends Error {}

function remainingMs() {
  return deadlineAt - Date.now();
}

function ensureTime(label) {
  if (remainingMs() <= 0) {
    throw new EnvironmentProblem(`watchdog (${deadlineMs} ms) expired before ${label}`);
  }
}

// ---------------------------------------------------------------------------
// Static file server (read-only, no SPA fallback)
// ---------------------------------------------------------------------------

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml",
  ".webmanifest": "application/manifest+json",
  ".map": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
};

function contentTypeFor(filePath) {
  return MIME_TYPES[path.extname(filePath).toLowerCase()] ?? "application/octet-stream";
}

function resolveWithinDist(pathname) {
  const decoded = decodeURIComponent(pathname);
  if (decoded.includes("\0")) return undefined;
  let relative = decoded;
  if (base !== "/") {
    if (!relative.startsWith(base)) return undefined;
    relative = relative.slice(base.length);
  } else {
    relative = relative.replace(/^\/+/, "");
  }
  const resolved = path.resolve(distDir, relative);
  const root = path.resolve(distDir);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) return undefined;
  return resolved;
}

function startServer() {
  const server = createServer((request, response) => {
    const send = (status, body, headers = {}) => {
      response.writeHead(status, { "cache-control": "no-store", ...headers });
      response.end(body);
    };
    if (request.method !== "GET" && request.method !== "HEAD") {
      send(405, "method not allowed", { "content-type": "text/plain; charset=utf-8" });
      return;
    }
    let pathname;
    try {
      pathname = new URL(request.url, "http://127.0.0.1").pathname;
    } catch {
      send(400, "bad request", { "content-type": "text/plain; charset=utf-8" });
      return;
    }
    const resolved = resolveWithinDist(pathname);
    if (!resolved) {
      send(404, readNotFound(), { "content-type": "text/html; charset=utf-8" });
      return;
    }
    let file = resolved;
    if (existsSync(file) && statSync(file).isDirectory()) file = path.join(file, "index.html");
    if (!existsSync(file) || !statSync(file).isFile()) {
      send(404, readNotFound(), { "content-type": "text/html; charset=utf-8" });
      return;
    }
    response.writeHead(200, {
      "content-type": contentTypeFor(file),
      "content-length": statSync(file).size,
      "cache-control": "no-store",
    });
    if (request.method === "HEAD") response.end();
    else createReadStream(file).pipe(response);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({ server, origin: `http://127.0.0.1:${address.port}` });
    });
  });
}

function readNotFound() {
  const file = path.join(distDir, "404.html");
  if (existsSync(file)) return readFileSync(file);
  return Buffer.from("<!doctype html><title>404</title><h1>404</h1>", "utf8");
}

// ---------------------------------------------------------------------------
// Browser helpers
// ---------------------------------------------------------------------------

async function importPlaywright() {
  // PLAYWRIGHT_MODULE is a test-only override, mirroring node-test/wasm/browser.mjs.
  const override = (process.env.PLAYWRIGHT_MODULE ?? "").trim();
  let loaded;
  try {
    loaded = override
      ? await import(pathToFileURL(override).href)
      : await import("playwright-core");
  } catch (error) {
    throw new EnvironmentProblem(
      `playwright-core is not installed (${error.message}). The site implementation is expected to add ` +
        "playwright-core@1.63.0 as a devDependency; install it and, in CI, its Chromium build.",
    );
  }
  // playwright-core is CommonJS: the namespace may expose `chromium` only
  // through `default`.
  const chromium = loaded.chromium ?? loaded.default?.chromium;
  if (!chromium) throw new EnvironmentProblem("playwright-core did not export chromium");
  return { chromium };
}

async function launchBrowser(chromium) {
  const executablePath = (process.env.CHROME_EXECUTABLE ?? "").trim() || undefined;
  try {
    return await chromium.launch({ executablePath, args: ["--no-sandbox"] });
  } catch (error) {
    throw new EnvironmentProblem(
      `could not launch Chromium (${error.message}). Set CHROME_EXECUTABLE, or install the browser ` +
        "matching playwright-core (for example: pnpm exec playwright install chromium).",
    );
  }
}

async function collectPageSignals(page, signals) {
  page.on("console", (message) => {
    if (message.type() === "error") signals.consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => signals.pageErrors.push(error.message));
  page.on("requestfailed", (request) => {
    const url = request.url();
    if (!url.startsWith(signals.origin)) return;
    signals.requestFailures.push(
      `${request.method()} ${url} (${request.failure()?.errorText ?? "failed"})`,
    );
  });
  page.on("response", (response) => {
    if (!response.url().startsWith(signals.origin)) return;
    // Chromium probes /favicon.ico on its own; that is not a site defect.
    if (new URL(response.url()).pathname === "/favicon.ico") return;
    if (response.status() >= 400)
      signals.badResponses.push(`${response.status()} ${response.url()}`);
  });
}

function newSignals(origin) {
  return { origin, consoleErrors: [], pageErrors: [], requestFailures: [], badResponses: [] };
}

function signalsAreClean(signals, { allowNotFound = false } = {}) {
  const bad = allowNotFound
    ? signals.badResponses.filter((entry) => !entry.startsWith("404 "))
    : signals.badResponses;
  return {
    clean:
      !signals.consoleErrors.length &&
      !signals.pageErrors.length &&
      !signals.requestFailures.length &&
      !bad.length,
    summary: [
      ...signals.consoleErrors.map((entry) => `console error: ${entry}`),
      ...signals.pageErrors.map((entry) => `page error: ${entry}`),
      ...signals.requestFailures.map((entry) => `failed request: ${entry}`),
      ...bad.map((entry) => `bad response: ${entry}`),
    ],
  };
}

async function openPage(context, origin, route, viewport) {
  ensureTime(`opening ${route || "/"}`);
  const page = await context.newPage();
  await page.setViewportSize(viewport);
  const signals = newSignals(origin);
  await collectPageSignals(page, signals);
  const response = await page.goto(`${origin}${base}${route}`, {
    waitUntil: "load",
    timeout: 20_000,
  });
  await page.waitForLoadState("domcontentloaded", { timeout: 10_000 }).catch(() => {});
  const status = response?.status() ?? 0;
  metrics.totals.pageLoads += 1;
  return { page, signals, status };
}

async function screenshot(page, name, options = {}) {
  const file = path.join(screenshotDir, `${name}.png`);
  await page.screenshot({ path: file, ...options });
  screenshots.push(file);
  metrics.totals.screenshots += 1;
  return file;
}

async function screenshotLocator(locator, name) {
  const file = path.join(screenshotDir, `${name}.png`);
  await locator.screenshot({ path: file });
  screenshots.push(file);
  metrics.totals.screenshots += 1;
  return file;
}

// ---------------------------------------------------------------------------
// Layout and semantics helpers
// ---------------------------------------------------------------------------

async function pageOverflow(page) {
  return page.evaluate(() => {
    const root = document.documentElement;
    const body = document.body;
    const clipped = (element) => {
      for (
        let node = element.parentElement;
        node && node !== document.body;
        node = node.parentElement
      ) {
        const style = getComputedStyle(node);
        if (
          /auto|scroll|hidden|clip/.test(style.overflowX) &&
          node.scrollWidth > node.clientWidth + 1
        )
          return true;
      }
      return false;
    };
    const offenders = [];
    for (const element of document.querySelectorAll("body *")) {
      const rect = element.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) continue;
      if (rect.right > root.clientWidth + 1 || rect.left < -1) {
        if (clipped(element)) continue;
        const style = getComputedStyle(element);
        offenders.push({
          tag: element.tagName.toLowerCase(),
          className: typeof element.className === "string" ? element.className.slice(0, 60) : "",
          overflowX: style.overflowX,
          left: Math.round(rect.left),
          right: Math.round(rect.right),
        });
      }
    }
    return {
      documentScrollWidth: root.scrollWidth,
      documentClientWidth: root.clientWidth,
      bodyScrollWidth: body.scrollWidth,
      innerWidth: window.innerWidth,
      devicePixelRatio: window.devicePixelRatio,
      offenders: offenders.slice(0, 8),
    };
  });
}

async function scriptBytes(page) {
  return page.evaluate(() => {
    const entries = performance
      .getEntriesByType("resource")
      .filter((entry) => entry.initiatorType === "script");
    const inline = [...document.querySelectorAll("script:not([src])")].reduce(
      (total, script) => total + (script.textContent?.length ?? 0),
      0,
    );
    return {
      scripts: document.querySelectorAll("script").length,
      external: entries.length,
      bytes:
        entries.reduce(
          (total, entry) => total + (entry.encodedBodySize || entry.transferSize || 0),
          0,
        ) + inline,
    };
  });
}

// Landmarks are addressed by their accessible name: `aria-label`, or the text
// of the element an `aria-labelledby` points at.
const NAV_NAME_HELPER = `
  const nameOf = (element) => {
    const label = element.getAttribute("aria-label");
    if (label && label.trim()) return label.trim();
    const ids = element.getAttribute("aria-labelledby");
    if (ids) {
      return ids
        .split(/\\s+/)
        .map((id) => document.getElementById(id)?.textContent?.trim() ?? "")
        .filter(Boolean)
        .join(" ");
    }
    return "";
  };
`;

async function navInventory(page) {
  return page.evaluate(
    `(() => {
      ${NAV_NAME_HELPER}
      return [...document.querySelectorAll("nav, [role='navigation']")].map((element) => ({
        label: nameOf(element),
        links: element.querySelectorAll("a[href]").length,
      }));
    })()`,
  );
}

async function activeNavInfo(page, name) {
  return page.evaluate(
    `(() => {
      ${NAV_NAME_HELPER}
      return [...document.querySelectorAll("nav, [role='navigation']")]
        .filter((element) => nameOf(element) === ${JSON.stringify(name)})
        .map((nav) => {
          const current = [...nav.querySelectorAll("[aria-current]")].filter(
            (element) => element.getAttribute("aria-current") !== "false",
          );
          return {
            count: nav.querySelectorAll("a[href]").length,
            currentCount: current.length,
            currentHref: current[0]?.getAttribute("href") ?? null,
            currentText: current[0]?.textContent?.trim() ?? null,
            visible: nav.getClientRects().length > 0,
          };
        });
    })()`,
  );
}

async function navPresentation(page, name) {
  return page.evaluate(
    `(() => {
      ${NAV_NAME_HELPER}
      const navs = [...document.querySelectorAll("nav, [role='navigation']")]
        .filter((element) => nameOf(element) === ${JSON.stringify(name)});
      return navs.map((nav) => {
        let scrollable = null;
        let node = nav;
        while (node && node !== document.body) {
          const style = getComputedStyle(node);
          if (node.scrollWidth > node.clientWidth + 4 && /auto|scroll/.test(style.overflowX)) {
            scrollable = { tag: node.tagName.toLowerCase(), scrollWidth: node.scrollWidth, clientWidth: node.clientWidth };
            break;
          }
          node = node.parentElement;
        }
        let positioning = null;
        let ancestor = nav;
        for (let depth = 0; depth < 5 && ancestor; depth += 1) {
          const style = getComputedStyle(ancestor);
          if (style.position === "sticky" || style.position === "fixed") {
            positioning = { position: style.position, tag: ancestor.tagName.toLowerCase() };
            break;
          }
          ancestor = ancestor.parentElement;
        }
        const anchor = [...nav.querySelectorAll("[aria-current]")].find(
          (element) => element.getAttribute("aria-current") !== "false",
        );
        const rect = nav.getBoundingClientRect();
        const anchorRect = anchor?.getBoundingClientRect() ?? null;
        return {
          visible: nav.getClientRects().length > 0,
          width: Math.round(rect.width),
          left: Math.round(rect.left),
          right: Math.round(rect.right),
          top: Math.round(rect.top),
          bottom: Math.round(rect.bottom),
          positioning,
          scrollable,
          anchor: anchorRect ? { left: Math.round(anchorRect.left), right: Math.round(anchorRect.right) } : null,
          viewport: { width: window.innerWidth, height: window.innerHeight },
        };
      });
    })()`,
  );
}

function visibleNav(navs) {
  return (navs ?? []).find((nav) => nav.visible);
}

// The desktop rail is a narrow, non-scrolling column; the mobile treatment is
// a horizontally scrollable (or bottom) bar.
function isDesktopRail(entry) {
  return Boolean(entry?.visible) && !entry.scrollable && entry.width > 0 && entry.width <= 260;
}

// The documentation shell must stay two columns wide: the navigation rail and
// the prose column. A third rail (for example a squeezed-in table of contents)
// would shrink the prose column, which the layout check catches.
async function docsShellColumns(page, proseWidth) {
  return page.evaluate(
    `(() => {
      ${NAV_NAME_HELPER}
      const article = document.querySelector("main article") ?? document.querySelector("main");
      const nav = [...document.querySelectorAll("nav, [role='navigation']")]
        .filter((element) => nameOf(element) !== "")
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return { label: nameOf(element), left: Math.round(rect.left), right: Math.round(rect.right), visible: element.getClientRects().length > 0 };
        })
        .filter((entry) => entry.visible);
      const articleRect = article?.getBoundingClientRect();
      const ranges = nav
        .filter((entry) => entry.right > entry.left)
        .map((entry) => ({ label: entry.label, left: entry.left, right: entry.right }));
      if (articleRect) ranges.push({ label: "prose", left: Math.round(articleRect.left), right: Math.round(articleRect.right) });
      return { ranges, articleWidth: articleRect ? Math.round(articleRect.width) : null, expectedProse: ${proseWidth} };
    })()`,
  );
}

// Column count: x-ranges that overlap belong to the same column.
function countColumns(ranges) {
  const sorted = [...ranges].sort((left, right) => left.left - right.left);
  let columns = 0;
  let currentRight = Number.NEGATIVE_INFINITY;
  for (const range of sorted) {
    if (range.left >= currentRight - 8) {
      columns += 1;
      currentRight = range.right;
    } else {
      currentRight = Math.max(currentRight, range.right);
    }
  }
  return columns;
}

// The browser's own fragment lookup: `:target` is set only when the browser
// really navigated to an element, which also covers published ids that contain
// percent sequences.
async function targetInfo(page) {
  return page.evaluate(() => {
    const target = document.querySelector(":target");
    return {
      hash: window.location.hash,
      id: target?.id ?? null,
      tag: target?.tagName?.toLowerCase() ?? null,
      top: target ? Math.round(target.getBoundingClientRect().top) : null,
    };
  });
}

async function textLineMetrics(locator, label) {
  if (!(await locator.count())) return { missing: true, label };
  return locator.first().evaluate((element, name) => {
    const range = document.createRange();
    range.selectNodeContents(element);
    const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
    const widths = rects.map((rect) => Math.round(rect.width));
    const style = getComputedStyle(element);

    // Word-level measurement: a wide last line can still be one orphaned word,
    // and a narrow one can carry several short words. Ranges over each word tell
    // us what actually sits on the final line.
    const words = [];
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent ?? "";
      const pattern = /\S+/g;
      for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
        const wordRange = document.createRange();
        wordRange.setStart(node, match.index);
        wordRange.setEnd(node, match.index + match[0].length);
        const rect = wordRange.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
          words.push({
            word: match[0],
            top: Math.round(rect.top),
            left: Math.round(rect.left),
            right: Math.round(rect.right),
          });
        }
      }
    }
    const wordLines = [];
    for (const word of words.slice().sort((a, b) => a.top - b.top || a.left - b.left)) {
      const line = wordLines.find((candidate) => Math.abs(candidate.top - word.top) <= 2);
      if (line) line.words.push(word);
      else wordLines.push({ top: word.top, words: [word] });
    }
    const lastLine = wordLines[wordLines.length - 1];
    // Rect counts above can split one visual line whenever an inline <code>
    // interrupts the text run, so the word grouping is the visual truth.
    const wordWidths = wordLines.map(
      (line) => line.words[line.words.length - 1].right - line.words[0].left,
    );

    return {
      label: name,
      lines: rects.length,
      lineWidths: widths,
      lastLineRatio: widths.length > 1 ? widths[widths.length - 1] / Math.max(...widths) : 1,
      visualLines: wordLines.length,
      visualLastLineWords: lastLine ? lastLine.words.length : 0,
      visualLastLineText: lastLine ? lastLine.words.map((word) => word.word).join(" ") : "",
      visualLastLineRatio:
        wordWidths.length > 1 ? wordWidths[wordWidths.length - 1] / Math.max(...wordWidths) : 1,
      fontSize: style.fontSize,
      containerWidth: Math.round(element.getBoundingClientRect().width),
      text: (element.textContent ?? "").trim().slice(0, 80),
    };
  }, label);
}

async function fontReport(page) {
  return page.evaluate(() => {
    const article = document.querySelector("main article") ?? document.querySelector("main");
    const body = document.body;
    const heading = document.querySelector("main h1") ?? document.querySelector("h1");
    const code = document.querySelector("main pre code, main code, pre code");
    const read = (element) => (element ? getComputedStyle(element) : null);
    const painted = (element) => {
      for (let node = element; node; node = node.parentElement) {
        const value = getComputedStyle(node).backgroundColor;
        if (value && value !== "rgba(0, 0, 0, 0)" && value !== "transparent") return value;
      }
      return getComputedStyle(document.body).backgroundColor;
    };
    const bodyStyle = read(body);
    const articleStyle = read(article);
    const headingStyle = read(heading);
    const codeStyle = read(code);
    return {
      bodyBackground: bodyStyle?.backgroundColor ?? null,
      articleBackground: articleStyle?.backgroundColor ?? null,
      backgroundColor: article ? painted(article) : (bodyStyle?.backgroundColor ?? null),
      bodyFontFamily: bodyStyle?.fontFamily ?? null,
      articleFontFamily: articleStyle?.fontFamily ?? null,
      bodyFontWeight: bodyStyle?.fontWeight ?? null,
      headingFontWeight: headingStyle?.fontWeight ?? null,
      headingFontFamily: headingStyle?.fontFamily ?? null,
      codeFontFamily: codeStyle?.fontFamily ?? null,
      articleWidth: article ? Math.round(article.getBoundingClientRect().width) : null,
    };
  });
}

async function inkBlueEvidence(page, name) {
  return page.evaluate((navName) => {
    const nav = [...document.querySelectorAll("nav, [role='navigation']")].find(
      (element) => (element.getAttribute("aria-label") ?? "") === navName,
    );
    if (!nav) return null;
    const current = [...nav.querySelectorAll("[aria-current]")].find(
      (element) => element.getAttribute("aria-current") !== "false",
    );
    if (!current) return null;
    const properties = [
      "color",
      "borderLeftColor",
      "borderBottomColor",
      "backgroundColor",
      "textDecorationColor",
      "outlineColor",
    ];
    const samples = [];
    for (const element of [current, current.parentElement, nav]) {
      if (!element) continue;
      const style = getComputedStyle(element);
      for (const property of properties) samples.push({ property, value: style[property] });
      const before = getComputedStyle(element, "::before");
      samples.push({ property: "::before backgroundColor", value: before.backgroundColor });
      samples.push({ property: "::before borderLeftColor", value: before.borderLeftColor });
    }
    return samples.filter((sample) => sample.value && sample.value !== "rgba(0, 0, 0, 0)");
  }, name);
}

function parseColor(value) {
  if (!value) return undefined;
  const match = /rgba?\(([^)]+)\)/.exec(value);
  if (!match) return undefined;
  const [r, g, b, a] = match[1].split(",").map((part) => Number.parseFloat(part));
  if ([r, g, b].some((channel) => !Number.isFinite(channel))) return undefined;
  if (a !== undefined && a < 0.85) return undefined; // too transparent to judge
  return { r, g, b };
}

function colorDistance(a, b) {
  return Math.max(Math.abs(a.r - b.r), Math.abs(a.g - b.g), Math.abs(a.b - b.b));
}

const INK_BLUE = { r: 0x1b, g: 0x36, b: 0x5d };
const PARCHMENT = [
  { r: 0xf5, g: 0xf4, b: 0xed },
  { r: 0xfa, g: 0xf9, b: 0xf5 },
];

// Transient UI states (for example a "Copied" label that resets itself) are
// sampled for a short window instead of being read once.
async function sampleFeedback(handle, durationMs = 2000, intervalMs = 25) {
  const samples = [];
  const started = Date.now();
  while (Date.now() - started < durationMs) {
    // Read the surrounding toolbar too: the label may flip from "Copy" to
    // "Copied", which would also change the button's accessible name and make
    // a role-based locator stop matching.
    const text = await handle
      .evaluate(
        (element) => (element.closest("[role='group'], div, p") ?? element).textContent ?? "",
      )
      .catch(() => "");
    const trimmed = text.replace(/\s+/g, " ").trim();
    if (trimmed && samples[samples.length - 1] !== trimmed) samples.push(trimmed);
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  return samples;
}

// ---------------------------------------------------------------------------
// Route sweeps
// ---------------------------------------------------------------------------

function canonicalRoutes() {
  return [
    { route: "", id: "home", label: "home" },
    ...TOPICS.map((topic) => ({
      route: routesForTopic(topic.id).route,
      id: topic.id,
      label: topic.id,
    })),
  ];
}

async function sweepRoute(origin, context, entry, viewport) {
  const { page, signals, status } = await openPage(context, origin, entry.route, viewport).catch(
    (error) => {
      record(`route ${entry.label} @${viewport.width}: load`, "fail", error.message);
      return {};
    },
  );
  if (!page) return;
  try {
    const slug = entry.label === "home" ? "home" : `api-${entry.id}`;
    await check(`route ${entry.label} @${viewport.width}: HTTP status`, async () => {
      assert.equal(status, 200, `expected 200, got ${status}`);
    });
    await check(
      `route ${entry.label} @${viewport.width}: no console or resource errors`,
      async () => {
        const { clean, summary } = signalsAreClean(signals);
        assert.ok(clean, summary.join("; "));
      },
    );
    await check(
      `route ${entry.label} @${viewport.width}: single main landmark and one H1`,
      async () => {
        const mains = await page.locator("main, [role='main']").count();
        assert.equal(mains, 1, `found ${mains} main landmarks`);
        const h1s = await page.locator("h1").count();
        assert.equal(h1s, 1, `found ${h1s} h1 elements`);
        const h1 = (await page.locator("h1").first().innerText()).trim();
        const expected = entry.id === "home" ? "zig-napi" : docsById.get(entry.id)?.title;
        assert.equal(h1, expected, `h1 text ${JSON.stringify(h1)} != ${JSON.stringify(expected)}`);
      },
    );
    await check(
      `route ${entry.label} @${viewport.width}: no horizontal page overflow`,
      async () => {
        const overflow = await pageOverflow(page);
        metrics.routes[`${entry.label}@${viewport.width}`] = {
          ...metrics.routes[`${entry.label}@${viewport.width}`],
          overflow,
        };
        assert.ok(
          overflow.documentScrollWidth <= overflow.documentClientWidth + 1,
          `document scrollWidth ${overflow.documentScrollWidth} > clientWidth ${overflow.documentClientWidth}; ` +
            `offenders: ${JSON.stringify(overflow.offenders)}`,
        );
        assert.equal(
          overflow.innerWidth,
          viewport.width,
          "viewport width is not reported in CSS pixels",
        );
      },
    );
    if (entry.id !== "home") {
      await check(
        `route ${entry.label} @${viewport.width}: API navigation marks the current page`,
        async () => {
          const navs = await activeNavInfo(page, "API sections");
          assert.ok(
            navs.length,
            `no nav named "API sections"; found ${JSON.stringify(await navInventory(page))}`,
          );
          for (const nav of navs) {
            assert.equal(nav.currentCount, 1, `nav has ${nav.currentCount} aria-current links`);
            assert.ok(nav.currentHref, "current link has no href");
            const expected = routesForTopic(entry.id).route.replace(/\/+$/, "");
            const href = nav.currentHref.replace(new RegExp(`^${base}`), "").replace(/\/+$/, "");
            assert.ok(
              [
                expected,
                ...routesForTopic(entry.id).acceptedAliases.map((value) =>
                  value.replace(/\/+$/, ""),
                ),
              ].includes(href),
              `aria-current points at ${href}, expected ${expected}`,
            );
          }
        },
      );
      await check(
        `route ${entry.label} @${viewport.width}: table of contents resolves`,
        async () => {
          const toc = page.getByRole("navigation", { name: "On this page" });
          if (!(await toc.count()))
            return "no table of contents navigation (none expected on short pages)";
          const links = toc.first().locator("a[href^='#']");
          const count = await links.count();
          for (let index = 0; index < count; index += 1) {
            const href = await links.nth(index).getAttribute("href");
            const target = page.locator(`[id="${href.slice(1)}"]`);
            const matches = await target.count();
            assert.equal(
              matches,
              1,
              `table of contents entry ${href} matches ${matches} elements (expected exactly one anchor target)`,
            );
          }
          return `${count} entries`;
        },
      );
    }
    await check(`route ${entry.label} @${viewport.width}: screenshots`, async () => {
      await screenshot(page, `${slug}-${viewport.width}`);
      const height = await page.evaluate(() => document.documentElement.scrollHeight);
      if (height <= 6000)
        await screenshot(page, `${slug}-${viewport.width}-full`, { fullPage: true });
      else
        metrics.routes[`${entry.label}@${viewport.width}`] = {
          ...metrics.routes[`${entry.label}@${viewport.width}`],
          fullPageSkipped: height,
        };
    });
    const bytes = await scriptBytes(page).catch(() => null);
    if (bytes) {
      metrics.routes[`${entry.label}@${viewport.width}`] = {
        ...metrics.routes[`${entry.label}@${viewport.width}`],
        scripts: bytes.scripts,
        jsBytes: bytes.bytes,
      };
    }
  } finally {
    await page.close().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  if (!existsSync(distDir)) {
    console.error(
      `dist directory not found: ${distDir}\nBuild first: pnpm --filter zig-napi-website run build`,
    );
    return 2;
  }
  const { chromium } = await importPlaywright();
  mkdirSync(screenshotDir, { recursive: true });
  const { server, origin } = await startServer();
  let browser;
  try {
    browser = await launchBrowser(chromium);
    const context = await browser.newContext({
      viewport: DESKTOP,
      deviceScaleFactor: 1,
      locale: "en-US",
    });

    // A dist built for a different base than SITE_BASE_PATH would 404 every
    // asset and link; report that once instead of per page.
    const baseProbe = await check("dist was built for the configured base path", async () => {
      const page = await context.newPage();
      try {
        await page.goto(`${origin}${base}`, { waitUntil: "load" });
        const prefixes = await page.evaluate(() => {
          const markers = ["_astro/", "logo/", "assets/", "zig-napi-pipeline.svg"];
          const found = new Set();
          for (const element of document.querySelectorAll("link[href], script[src], img[src]")) {
            const value = element.getAttribute("href") ?? element.getAttribute("src") ?? "";
            if (!value || /^[a-z]+:|^#|^\/\//i.test(value)) continue;
            for (const marker of markers) {
              const index = value.indexOf(marker);
              if (index === -1) continue;
              found.add(value.slice(0, index));
              break;
            }
          }
          return [...found];
        });
        assert.equal(
          prefixes.length,
          1,
          `home page mixes asset prefixes ${JSON.stringify(prefixes)}`,
        );
        metrics.builtBase = prefixes[0];
        assert.equal(
          prefixes[0],
          base,
          `dist assets are prefixed with ${JSON.stringify(prefixes[0])} but the tests are configured for ` +
            `${JSON.stringify(base)}; rebuild or set SITE_BASE_PATH to match`,
        );
        return `base ${base}`;
      } finally {
        await page.close();
      }
    });
    if (!baseProbe) {
      console.error("aborting: fix the base path mismatch before the browser sweep");
      return 1;
    }

    // ---- route sweep: 375px and 1280px -------------------------------
    for (const entry of canonicalRoutes()) {
      ensureTime(`route ${entry.label}`);
      await sweepRoute(origin, context, entry, DESKTOP);
      ensureTime(`route ${entry.label} (mobile)`);
      await sweepRoute(origin, context, entry, MOBILE);
    }

    // ---- extra visual evidence ---------------------------------------
    await check("home #build section renders the recipe tabs", async () => {
      const { page } = await openPage(context, origin, "", DESKTOP);
      try {
        const section = page.locator("#build");
        assert.equal(await section.count(), 1, "no #build section to screenshot");
        await section.scrollIntoViewIfNeeded();
        await screenshotLocator(section, "home-build-section-1280");
        const panel = page.locator("[role='tabpanel']:visible").first();
        if (await panel.count()) await screenshotLocator(panel, "home-build-panel-1280");
      } finally {
        await page.close();
      }
    });

    await check("long documentation page shows code, table and pager regions", async () => {
      const { page } = await openPage(
        context,
        origin,
        routesForTopic("classes-ownership").route,
        DESKTOP,
      );
      try {
        const firstCode = page.locator("main pre").first();
        assert.equal(await firstCode.count(), 1, "no code block on the long documentation page");
        await firstCode.scrollIntoViewIfNeeded();
        await screenshotLocator(firstCode, "api-classes-ownership-code-1280");
        const table = page.locator("main table").first();
        if (await table.count()) {
          await table.scrollIntoViewIfNeeded();
          await screenshotLocator(table, "api-classes-ownership-table-1280");
        }
        const pager = page.getByRole("navigation", { name: "API document navigation" }).first();
        if (await pager.count()) {
          await pager.scrollIntoViewIfNeeded();
          await screenshotLocator(pager, "api-classes-ownership-pager-1280");
        }
      } finally {
        await page.close();
      }
    });

    await check("320px home call to action and documentation table", async () => {
      const home = await openPage(context, origin, "", NARROW);
      try {
        const cta = home.page.getByRole("link", { name: "Start with ZON" }).first();
        await cta.scrollIntoViewIfNeeded();
        await screenshotLocator(
          cta.locator("xpath=ancestor::*[self::div or self::section][1]"),
          "home-cta-320",
        );
        await screenshot(home.page, "home-320");
      } finally {
        await home.page.close();
      }
      const doc = await openPage(context, origin, routesForTopic("binary-data").route, NARROW);
      try {
        const table = doc.page.locator("main table").first();
        if (await table.count()) {
          await table.scrollIntoViewIfNeeded();
          await screenshotLocator(table, "api-binary-data-table-320");
        }
        const overflow = await pageOverflow(doc.page);
        assert.ok(
          overflow.documentScrollWidth <= overflow.documentClientWidth + 1,
          `320px page overflows: ${JSON.stringify(overflow)}`,
        );
      } finally {
        await doc.page.close();
      }
    });

    // ---- design tokens (kami summary) --------------------------------
    await check("desktop documentation layout keeps the kami rails", async () => {
      const { page } = await openPage(context, origin, routesForTopic("build-node").route, DESKTOP);
      try {
        const nav = visibleNav(await navPresentation(page, "API sections"));
        assert.ok(nav, "API navigation is not visible at 1280px");
        assert.ok(nav.positioning, "desktop API rail is not sticky or fixed");
        assert.ok(
          nav.width >= 140 && nav.width <= 220,
          `sidebar rail is ${nav.width}px wide, expected about 178px`,
        );
        const fonts = await fontReport(page);
        const background = parseColor(fonts.backgroundColor);
        assert.ok(background, `could not read the page background (${fonts.backgroundColor})`);
        const distances = PARCHMENT.map((tone) => colorDistance(background, tone));
        assert.ok(
          Math.min(...distances) <= 12,
          `page background ${fonts.backgroundColor} is not the parchment tone (#f5f4ed / #faf9f5)`,
        );
        const serif = `${fonts.articleFontFamily} ${fonts.bodyFontFamily}`.toLowerCase();
        assert.ok(/georgia|charter|serif/.test(serif), `body is not serif: ${serif}`);
        const bodyWeight = Number.parseInt(fonts.bodyFontWeight, 10);
        assert.ok(
          bodyWeight >= 350 && bodyWeight <= 450,
          `body weight is ${fonts.bodyFontWeight}, expected 400`,
        );
        const headingWeight = Number.parseInt(fonts.headingFontWeight, 10);
        assert.ok(
          headingWeight >= 450 && headingWeight <= 560,
          `heading weight is ${fonts.headingFontWeight}, expected 500`,
        );
        assert.ok(
          /mono/i.test(fonts.codeFontFamily ?? ""),
          `code is not monospace: ${fonts.codeFontFamily}`,
        );
        assert.ok(
          fonts.articleWidth !== null && fonts.articleWidth >= 640 && fonts.articleWidth <= 780,
          `prose column is ${fonts.articleWidth}px wide, expected about 720px`,
        );
        // Two-column shell: the rail plus the prose column, with no third
        // column (for example a table of contents rail) squeezing the prose.
        const shell = await docsShellColumns(page, fonts.articleWidth);
        const columns = countColumns(shell.ranges);
        assert.ok(
          columns <= 2,
          `documentation shell has ${columns} columns: ${JSON.stringify(shell.ranges)}`,
        );
        metrics.design = { fonts, nav, docsShell: { ...shell, columns } };
        return `rail ${nav.width}px (${nav.positioning.position}), prose ${fonts.articleWidth}px, ${columns} columns`;
      } finally {
        await page.close();
      }
    });

    await check("active navigation uses the ink blue accent", async () => {
      const { page } = await openPage(context, origin, routesForTopic("versioning").route, DESKTOP);
      try {
        const samples = await inkBlueEvidence(page, "API sections");
        assert.ok(samples?.length, "no computed colours to inspect on the current navigation item");
        const match = samples.find((sample) => {
          const color = parseColor(sample.value);
          return color && colorDistance(color, INK_BLUE) <= 16;
        });
        metrics.design = { ...metrics.design, inkBlueSamples: samples.slice(0, 12) };
        assert.ok(
          match,
          `no ink blue (#1B365D) on the current navigation item; samples: ${JSON.stringify(samples.slice(0, 8))}`,
        );
      } finally {
        await page.close();
      }
    });

    await check("breakpoint switches between rail and mobile navigation", async () => {
      // Kami keeps the 880px breakpoint: above it the rail is visible, below it
      // the horizontal navigation takes over.
      for (const width of [900, 860]) {
        const { page } = await openPage(context, origin, routesForTopic("overview").route, {
          width,
          height: 800,
        });
        try {
          const navs = await navPresentation(page, "API sections");
          if (width === 900) {
            const rail = navs.find(isDesktopRail);
            assert.ok(
              rail &&
                (rail.positioning?.position === "sticky" || rail.positioning?.position === "fixed"),
              `no narrow sticky rail above the 880px breakpoint: ${JSON.stringify(navs)}`,
            );
          }
          if (width === 860) {
            const horizontal = navs.some((entry) => entry.visible && entry.scrollable);
            assert.ok(
              horizontal && !navs.some(isDesktopRail),
              `at 860px the desktop rail is still active (${JSON.stringify(navs)})`,
            );
          }
        } finally {
          await page.close();
        }
      }
    });

    await check("mobile navigation keeps the current item reachable", async () => {
      const { page } = await openPage(
        context,
        origin,
        routesForTopic("errors-results").route,
        MOBILE,
      );
      try {
        const nav = visibleNav(await navPresentation(page, "API sections"));
        assert.ok(nav, "API navigation is not visible at 375px");
        assert.ok(nav.anchor, "mobile navigation has no aria-current item");
        metrics.design = { ...metrics.design, mobileNav: nav };
        const scrollable = Boolean(nav.scrollable);
        const bottomRail =
          nav.positioning?.position === "fixed" || nav.top > nav.viewport.height / 2;
        assert.ok(
          scrollable || bottomRail,
          `mobile navigation is neither scrollable nor a bottom rail: ${JSON.stringify(nav)}`,
        );
        const active = page.locator("nav[aria-label='API sections'] [aria-current]").first();
        await active.scrollIntoViewIfNeeded();
        assert.ok(
          await active.isVisible(),
          "the current navigation item cannot be scrolled into view",
        );
        const activeBox = await active.boundingBox();
        assert.ok(
          activeBox && activeBox.x >= -1 && activeBox.x + activeBox.width <= nav.viewport.width + 1,
          `the current navigation item stays outside the ${nav.viewport.width}px viewport after scrolling: ${JSON.stringify(activeBox)}`,
        );
        // following a navigation link must really change the page
        const before = page.url();
        const link = page.locator("nav[aria-label='API sections'] a[href]").first();
        await link.click();
        await page.waitForLoadState("load");
        assert.notEqual(page.url(), before, "clicking a navigation link did not change the URL");
        const h1 = (await page.locator("h1").first().innerText()).trim();
        assert.ok(h1.length > 0, "navigation target has no heading");
        assert.equal(await page.locator("main").count(), 1, "navigation target is not a full page");
      } finally {
        await page.close();
      }
    });

    await check("browser history, deep links and refresh work", async () => {
      const { page, signals } = await openPage(context, origin, "", DESKTOP);
      try {
        await page.getByRole("link", { name: "API", exact: true }).first().click();
        await page.waitForURL(/\/api\/?$/, { timeout: 10_000 });
        const apiHeading = (await page.locator("h1").first().innerText()).trim();
        await page
          .getByRole("navigation", { name: "API sections" })
          .first()
          .locator("a[href]")
          .nth(3)
          .click();
        await page.waitForLoadState("load");
        const deepUrl = page.url();
        const deepHeading = (await page.locator("h1").first().innerText()).trim();
        assert.notEqual(deepHeading, apiHeading, "navigation did not change the document");
        await page.goBack({ waitUntil: "load" });
        assert.equal(
          (await page.locator("h1").first().innerText()).trim(),
          apiHeading,
          "going back did not restore the previous document",
        );
        await page.goForward({ waitUntil: "load" });
        assert.equal(
          (await page.locator("h1").first().innerText()).trim(),
          deepHeading,
          "going forward failed",
        );
        await page.reload({ waitUntil: "load" });
        assert.equal(page.url(), deepUrl, "deep link URL changed after refresh");
        assert.equal(
          (await page.locator("h1").first().innerText()).trim(),
          deepHeading,
          "deep link did not survive a refresh (no SPA fallback expected)",
        );
        const { clean, summary } = signalsAreClean(signals);
        assert.ok(clean, summary.join("; "));
      } finally {
        await page.close();
      }
    });

    await check("skip link moves focus to the main content", async () => {
      const { page } = await openPage(context, origin, routesForTopic("overview").route, DESKTOP);
      try {
        const mainId = await page.evaluate(() => document.querySelector("main")?.id ?? null);
        assert.ok(mainId, "the main landmark has no id, so the skip link cannot target it");
        await page.keyboard.press("Tab");
        const focused = await page.evaluate(() => {
          const element = document.activeElement;
          if (!element) return null;
          const rect = element.getBoundingClientRect();
          return {
            tag: element.tagName.toLowerCase(),
            text: (element.textContent ?? "").trim().slice(0, 40),
            href: element.getAttribute("href"),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          };
        });
        assert.ok(focused, "nothing received focus after Tab");
        assert.equal(
          focused.tag,
          "a",
          `first focus stop is <${focused.tag}>, expected the skip link`,
        );
        assert.ok(
          /skip/i.test(focused.text),
          `first focus stop is ${JSON.stringify(focused.text)}, expected the skip link`,
        );
        assert.equal(
          focused.href,
          `#${mainId}`,
          `skip link points at ${focused.href}, expected #${mainId}`,
        );
        assert.ok(
          focused.width > 0 && focused.height > 0,
          `the skip link is not visible while focused (${focused.width}x${focused.height})`,
        );
        await page.keyboard.press("Enter");
        await page.waitForFunction((id) => document.querySelector(":target")?.id === id, mainId, {
          timeout: 5000,
        });
        const target = await targetInfo(page);
        assert.equal(
          target.id,
          mainId,
          `skip link moved to ${JSON.stringify(target)}, expected #${mainId}`,
        );
        assert.equal(target.tag, "main", `skip link target is <${target.tag}>, expected <main>`);
        metrics.skipLink = { target: mainId, text: focused.text };
        return `focus -> ${JSON.stringify(focused.text)} -> #${mainId}`;
      } finally {
        await page.close();
      }
    });

    await check("published fragments navigate with the browser's own lookup", async () => {
      // Ids published before the migration contain literal percent sequences
      // and underscores; clicking the emitted link has to land on them.
      const probes = [
        { id: "classes-ownership", fragment: "#calls%2C-receivers-and-factories" },
        { id: "module-registration", fragment: "#node_api_module" },
        { id: "errors-results", fragment: "#jserror%2C-jstypeerror%2C-jsrangeerror" },
      ];
      const report = [];
      for (const probe of probes) {
        const route = routesForTopic(probe.id).route;
        const { page } = await openPage(context, origin, route, DESKTOP);
        try {
          const link = page.locator(`a[href="${probe.fragment}"]`).first();
          assert.equal(await link.count(), 1, `no link with href ${probe.fragment} on ${route}`);
          await link.click();
          await page.waitForFunction(() => document.querySelector(":target") !== null, undefined, {
            timeout: 5000,
          });
          const target = await targetInfo(page);
          const raw = probe.fragment.slice(1);
          const decoded = decodeURIComponent(raw);
          assert.ok(
            target.id,
            `${probe.fragment} did not move the browser to any element (:target is empty)`,
          );
          assert.ok(
            [raw, decoded].includes(target.id),
            `:target is ${JSON.stringify(target.id)}, expected ${JSON.stringify(raw)}`,
          );
          assert.ok(
            target.top !== null && target.top >= -60 && target.top <= 320,
            `the fragment target sits at ${target.top}px, so the page did not scroll to it`,
          );
          report.push({ route, fragment: probe.fragment, target: target.id, top: target.top });
        } finally {
          await page.close();
        }
      }
      metrics.fragments = report;
      return report.map((entry) => `${entry.fragment} -> ${entry.target}`).join(", ");
    });

    await check("build recipe deep links open the matching recipe", async () => {
      const anchor = "#build-openharmony";
      const { page } = await openPage(context, origin, anchor, DESKTOP);
      try {
        const target = await targetInfo(page);
        assert.equal(
          target.id,
          "build-openharmony",
          `${anchor} landed on ${JSON.stringify(target.id)}`,
        );
        const panel = page.locator('[id="build-openharmony"]');
        assert.equal(
          await panel.count(),
          1,
          `no panel with id ${JSON.stringify("build-openharmony")}`,
        );
        assert.ok(await panel.isVisible(), `${anchor} panel is not visible after the deep link`);
        const tabs = page.getByRole("tablist", { name: "Build recipe snippets" });
        if (await tabs.count()) {
          const selected = (
            await tabs.getByRole("tab", { selected: true }).first().innerText()
          ).trim();
          assert.equal(
            selected,
            "OpenHarmony",
            `${anchor} opened the ${JSON.stringify(selected)} recipe instead of the linked one`,
          );
        }
        await page.goto(`${origin}${base}#build-node`, { waitUntil: "load" });
        const nodePanel = page.locator('[id="build-node"]');
        assert.ok(
          await nodePanel.isVisible(),
          "#build-node panel is not visible after the deep link",
        );
        metrics.buildDeepLinks = { openharmony: target.id, node: "build-node" };
        return `${anchor} -> visible panel`;
      } finally {
        await page.close();
      }
    });

    await check("unknown routes return the 404 document", async () => {
      const { page, status } = await openPage(context, origin, "definitely-not-a-page/", MOBILE);
      try {
        assert.equal(status, 404, `expected 404 for an unknown route, got ${status}`);
        const text = collapseWhitespace(await page.locator("body").innerText());
        assert.ok(/404|not found/i.test(text), "404 page does not explain the missing page");
      } finally {
        await page.close();
      }
    });

    // ---- progressive enhancement -------------------------------------
    await check("reading works without JavaScript", async () => {
      const noJs = await browser.newContext({
        viewport: MOBILE,
        javaScriptEnabled: false,
        locale: "en-US",
      });
      try {
        for (const [label, route] of [
          ["home", ""],
          ["overview", routesForTopic("overview").route],
        ]) {
          const page = await noJs.newPage();
          const response = await page.goto(`${origin}${base}${route}`, { waitUntil: "load" });
          assert.equal(response?.status(), 200, `no-JS ${label} page did not load`);
          assert.equal(
            await page.locator("h1").count(),
            1,
            `no-JS ${label} page has no single heading`,
          );
          assert.ok(
            await page.locator("main").first().isVisible(),
            `no-JS ${label} content is not visible`,
          );
          const body = collapseWhitespace(await page.locator("body").innerText());
          assert.ok(
            body.length > 400,
            `no-JS ${label} page looks empty (${body.length} characters)`,
          );
          await page.close();
        }
        const page = await noJs.newPage();
        await page.goto(`${origin}${base}`, { waitUntil: "load" });
        // Read the rendered text, not the markup: the highlighter splits code
        // into spans, so raw HTML never contains the plain code.
        const codeTexts = (await page.locator("main pre").allTextContents()).map((text) =>
          collapseWhitespace(text),
        );
        for (const snippet of snippets) {
          const code = collapseWhitespace(trimCode(snippet.code));
          assert.ok(
            codeTexts.some((text) => text.includes(code)),
            `build recipe ${snippet.label} is not available without JavaScript`,
          );
        }
        // Every recipe stays readable and reachable without the script: the
        // panels are linked sections and each one is visible.
        for (const snippet of snippets) {
          const panel = page.locator(`[id="build-${snippet.id}"]`);
          assert.equal(await panel.count(), 1, `no-JS: no panel for ${snippet.label}`);
          assert.ok(await panel.isVisible(), `no-JS: the ${snippet.label} recipe is not readable`);
        }
        const panels = await page.locator("[role='tabpanel'], main pre").allTextContents();
        metrics.noJavaScript = { panels: panels.length };
        await page.close();
        // A deep link must reveal the linked recipe without JavaScript too.
        const deep = await noJs.newPage();
        await deep.goto(`${origin}${base}#build-node`, { waitUntil: "load" });
        const nodePanel = deep.locator('[id="build-node"]');
        assert.equal(await nodePanel.count(), 1, "no-JS: #build-node panel is missing");
        assert.ok(
          await nodePanel.isVisible(),
          "no-JS: #build-node recipe is not readable after the deep link",
        );
        await deep.close();
      } finally {
        await noJs.close();
      }
    });

    await check(
      "build recipe tabs switch, keep roving tabindex and copy the active code",
      async () => {
        const { page } = await openPage(context, origin, "", DESKTOP);
        try {
          const tablist = page.getByRole("tablist", { name: "Build recipe snippets" });
          assert.equal(await tablist.count(), 1, "no tab list named 'Build recipe snippets'");
          const tabs = tablist.getByRole("tab");
          assert.equal(await tabs.count(), snippets.length, "unexpected number of recipe tabs");
          for (let index = 0; index < snippets.length; index += 1) {
            const tab = tabs.nth(index);
            const expectedLabel = snippets[index].label;
            assert.equal(
              (await tab.innerText()).trim(),
              expectedLabel,
              `tab #${index + 1} label changed`,
            );
            await tab.click();
            await page.waitForFunction(
              (label) => {
                const selected = [
                  ...document.querySelectorAll("[role='tab'][aria-selected='true']"),
                ];
                return selected.length === 1 && selected[0].textContent.trim() === label;
              },
              expectedLabel,
              { timeout: 5000 },
            );
            const selectedCount = await tablist
              .locator("[role='tab'][aria-selected='true']")
              .count();
            assert.equal(
              selectedCount,
              1,
              `expected exactly one selected tab, found ${selectedCount}`,
            );
            const panelId = await tab.getAttribute("aria-controls");
            assert.ok(panelId, `tab ${expectedLabel} has no aria-controls`);
            const panel = page.locator(`[id="${panelId}"]`);
            assert.equal(await panel.count(), 1, `tab ${expectedLabel} points at a missing panel`);
            assert.ok(
              await panel.isVisible(),
              `panel for ${expectedLabel} is not visible after selecting it`,
            );
            const visiblePanels = await page.locator("[role='tabpanel']:visible").count();
            assert.equal(visiblePanels, 1, `expected one visible panel, found ${visiblePanels}`);
            const text = collapseWhitespace(await panel.innerText());
            const wanted = collapseWhitespace(trimCode(snippets[index].code));
            assert.ok(
              text.includes(wanted.slice(0, 60)) && text.includes(wanted.slice(-40)),
              `panel for ${expectedLabel} does not show the recipe code`,
            );
            const tabindex = await tab.getAttribute("tabindex");
            assert.ok(
              tabindex === null || tabindex === "0",
              `selected tab ${expectedLabel} has tabindex=${tabindex}`,
            );
          }
          // keyboard: roving tabindex with arrow keys, Home and End
          const keyboard = async (key, expectedIndex) => {
            await page.keyboard.press(key);
            const label = (
              await tablist.locator("[role='tab'][aria-selected='true']").first().innerText()
            ).trim();
            assert.equal(
              label,
              snippets[expectedIndex].label,
              `${key} did not move selection as expected`,
            );
            const focused = await page.evaluate(
              () => document.activeElement?.textContent?.trim() ?? "",
            );
            assert.equal(
              focused,
              snippets[expectedIndex].label,
              `${key} left focus on ${JSON.stringify(focused)}`,
            );
            const tabindexes = await tablist
              .locator("[role='tab']")
              .evaluateAll((elements) =>
                elements.map((element) => element.getAttribute("tabindex") ?? "0"),
              );
            const zeros = tabindexes.filter((value) => value === "0").length;
            assert.equal(zeros, 1, `roving tabindex is broken: ${JSON.stringify(tabindexes)}`);
          };
          await tabs.nth(0).click();
          await tabs.nth(0).focus();
          await keyboard("ArrowRight", 1);
          await keyboard("ArrowRight", 2);
          await keyboard("ArrowLeft", 1);
          await keyboard("End", snippets.length - 1);
          await keyboard("Home", 0);
        } finally {
          await page.close();
        }
      },
    );

    for (const [mode, behaviour] of [
      ["success", "resolve"],
      ["failure", "reject"],
    ]) {
      await check(`copy button reports ${mode} truthfully`, async () => {
        const contextWithClipboard = await browser.newContext({
          viewport: DESKTOP,
          locale: "en-US",
        });
        await contextWithClipboard.addInitScript((outcome) => {
          window.__copyCalls = [];
          const writeText = (text) => {
            window.__copyCalls.push(text);
            return outcome === "resolve"
              ? Promise.resolve()
              : Promise.reject(new Error("clipboard denied"));
          };
          Object.defineProperty(navigator, "clipboard", {
            configurable: true,
            value: { writeText },
          });
        }, behaviour);
        const page = await contextWithClipboard.newPage();
        try {
          await page.goto(`${origin}${base}`, { waitUntil: "load" });
          const tablist = page.getByRole("tablist", { name: "Build recipe snippets" });
          const secondTab = tablist.getByRole("tab").nth(1);
          await secondTab.click();
          const visiblePanel = page.locator("[role='tabpanel']:visible").first();
          const copyButton = (await visiblePanel.count())
            ? visiblePanel.getByRole("button", { name: /copy|select/i }).first()
            : page.getByRole("button", { name: /copy|select/i }).first();
          assert.equal(await copyButton.count(), 1, "no copy button found on the home page");
          const handle = await copyButton.elementHandle();
          assert.ok(handle, "copy button is not attached to the DOM");
          const baseline = ((await handle.textContent()) ?? "").trim();
          await handle.click();
          const calls = await page.evaluate(() => window.__copyCalls ?? []);
          assert.equal(calls.length, 1, `clipboard.writeText was called ${calls.length} times`);
          const expectedCode = collapseWhitespace(trimCode(snippets[1].code));
          assert.equal(
            collapseWhitespace(calls[0]),
            expectedCode,
            "the copy button did not copy the code of the selected recipe",
          );
          const feedbackSamples = await sampleFeedback(handle);
          const status = collapseWhitespace(
            await page
              .locator("[role='status'], [aria-live]")
              .first()
              .innerText()
              .catch(() => ""),
          );
          const feedbackText = `${feedbackSamples.join(" | ")} ${status}`.trim();
          metrics.clipboard = {
            ...metrics.clipboard,
            [`${mode}Samples`]: feedbackSamples,
            [`${mode}Status`]: status,
          };
          if (mode === "success") {
            assert.ok(
              feedbackSamples.some((sample) => /copied/i.test(sample)) || /copied/i.test(status),
              `success feedback is not a "Copied" state (observed ${JSON.stringify(feedbackSamples)}, baseline ${JSON.stringify(baseline)})`,
            );
          } else {
            assert.ok(
              !feedbackSamples.some((sample) => /copied/i.test(sample)) && !/copied/i.test(status),
              `failure was reported as success: ${JSON.stringify(feedbackText)}`,
            );
            const selectable = await page.evaluate(() => {
              const panels = [...document.querySelectorAll("[role='tabpanel']")];
              const visible = panels.find((panel) => panel.getClientRects().length > 0);
              const code = (visible ?? document).querySelector("pre code, pre");
              if (!code) return null;
              const range = document.createRange();
              range.selectNodeContents(code);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              return selection.toString();
            });
            const wanted = collapseWhitespace(trimCode(snippets[1].code));
            assert.ok(selectable, "no code element to select after a copy failure");
            assert.equal(
              collapseWhitespace(selectable),
              wanted,
              "the recipe code cannot be selected after a copy failure",
            );
          }
          metrics.clipboard = {
            ...metrics.clipboard,
            [mode]: { feedback: feedbackText, calls: calls.length },
          };
        } finally {
          await page.close();
          await contextWithClipboard.close();
        }
      });
    }

    await check("reduced motion keeps content visible and still", async () => {
      const reduced = await browser.newContext({
        viewport: DESKTOP,
        reducedMotion: "reduce",
        locale: "en-US",
      });
      const page = await reduced.newPage();
      try {
        await page.goto(`${origin}${base}`, { waitUntil: "load" });
        const animations = await page.evaluate(() =>
          document.getAnimations().map((animation) => {
            const timing = animation.effect?.getTiming?.() ?? {};
            return { duration: Number(timing.duration) || 0, iterations: timing.iterations ?? 1 };
          }),
        );
        const longRunning = animations.filter(
          (animation) => animation.duration > 500 || animation.iterations === Infinity,
        );
        assert.deepEqual(
          longRunning,
          [],
          `animations still run under reduced motion: ${JSON.stringify(longRunning)}`,
        );
        const hero = page.locator("h1").first();
        assert.ok(await hero.isVisible(), "hero heading is hidden under reduced motion");
        const opacity = await hero.evaluate((element) => getComputedStyle(element).opacity);
        assert.equal(Number(opacity), 1, `hero heading opacity is ${opacity} under reduced motion`);
        const tagline = page.locator("h1").first().locator("xpath=following-sibling::p[1]");
        if (await tagline.count()) {
          assert.ok(
            await tagline.first().isVisible(),
            "hero tagline is hidden under reduced motion",
          );
        }
        metrics.reducedMotion = { animations: animations.length, longRunning: longRunning.length };
      } finally {
        await page.close();
        await reduced.close();
      }
    });

    await check("keyboard focus is visibly outlined", async () => {
      const { page } = await openPage(context, origin, "", DESKTOP);
      try {
        const stops = [];
        for (let index = 0; index < 3; index += 1) {
          await page.keyboard.press("Tab");
          const style = await page.evaluate(() => {
            const element = document.activeElement;
            if (!element) return null;
            const computed = getComputedStyle(element);
            return {
              tag: element.tagName.toLowerCase(),
              text: (element.textContent ?? "").trim().slice(0, 40),
              outlineStyle: computed.outlineStyle,
              outlineWidth: computed.outlineWidth,
              outlineColor: computed.outlineColor,
              boxShadow: computed.boxShadow,
            };
          });
          stops.push(style);
        }
        metrics.focusStops = stops;
        const outlined = stops.filter(
          (stop) =>
            stop &&
            ((stop.outlineStyle !== "none" && Number.parseFloat(stop.outlineWidth) >= 1) ||
              stop.boxShadow !== "none"),
        );
        assert.equal(
          outlined.length,
          stops.length,
          `focus is not visible on every stop: ${JSON.stringify(stops)}`,
        );
      } finally {
        await page.close();
      }
    });

    await check("UI copy surfaces stay on one line", async () => {
      const surfaces = [
        {
          viewport: DESKTOP,
          route: "",
          targets: [
            {
              selector: "main a:has-text('Start with ZON'), a:has-text('Start with ZON')",
              label: "hero CTA",
            },
            { selector: "a:has-text('API Reference')", label: "hero CTA 2" },
            { selector: "[role='tab']", label: "recipe chip" },
            { selector: "footer span", label: "footer label" },
          ],
        },
        {
          viewport: MOBILE,
          route: "",
          targets: [
            { selector: "a:has-text('Start with ZON')", label: "hero CTA" },
            { selector: "[role='tab']", label: "recipe chip" },
          ],
        },
      ];
      const measurements = [];
      for (const surface of surfaces) {
        const { page } = await openPage(context, origin, surface.route, surface.viewport);
        try {
          for (const target of surface.targets) {
            const locator = page.locator(target.selector).first();
            if (!(await locator.count())) continue;
            const report = await locator.evaluate((element) => {
              const range = document.createRange();
              range.selectNodeContents(element);
              const rects = [...range.getClientRects()].filter(
                (rect) => rect.width > 0 && rect.height > 0,
              );
              return { lines: rects.length, text: (element.textContent ?? "").trim().slice(0, 40) };
            });
            measurements.push({ viewport: surface.viewport.width, label: target.label, ...report });
            assert.equal(
              report.lines,
              1,
              `${target.label} ${JSON.stringify(report.text)} wraps onto ${report.lines} lines at ${surface.viewport.width}px`,
            );
          }
        } finally {
          await page.close();
        }
      }
      metrics.copySurfaces = measurements;
      return `${measurements.length} surfaces measured`;
    });

    // Display copy only: the hero tagline, the plain-sentence section ledes and
    // the descriptive footer lines. Technical prose (`article.prose`) and code
    // are deliberately out of scope — they wrap wherever the measure ends.
    // A surface that fits on one line is a label, not a widow, so it passes.
    await check("hero and footer copy show no line widows", async () => {
      const probes = [];
      const widowed = [];
      const viewports = [NARROW, MOBILE, DESKTOP];
      for (const viewport of viewports) {
        const { page } = await openPage(context, origin, "", viewport);
        try {
          const surfaces = [
            ["hero tagline", page.locator("main header.hero p.tagline")],
            ["install lede", page.locator("section#install .section-lede")],
            ["reference lede", page.locator("section:last-of-type .section-lede")],
            ["footer brand line", page.locator("footer .wm-line")],
            ["footer ethos", page.locator("footer .ethos")],
          ];
          for (const [label, locator] of surfaces) {
            const probe = await textLineMetrics(locator, `${label} @${viewport.width}`);
            probes.push(probe);
            if (probe.missing) {
              // A vanished copy surface is a defect of its own, never a silent skip.
              widowed.push({ ...probe, reason: "surface not found" });
              continue;
            }
            if (probe.visualLines <= 1) continue;
            if (probe.visualLastLineWords === 1) {
              widowed.push({ ...probe, reason: "single word on the last line" });
            } else if (probe.visualLastLineRatio < 0.12) {
              widowed.push({ ...probe, reason: "last line too short for its measure" });
            }
          }
        } finally {
          await page.close();
        }
      }
      metrics.lineWidows = { probes, widowed };
      assert.deepEqual(
        widowed.map((probe) => `${probe.label}: ${probe.reason ?? "widow"}`),
        [],
        `copy surfaces with a single-word or short last line (visual review needed): ${JSON.stringify(widowed)}`,
      );
      return `${probes.length} copy surfaces measured across ${viewports.length} widths`;
    });

    return metrics.totals.failures === 0 ? 0 : 1;
  } finally {
    metrics.visualReview.screenshots = screenshots;
    metrics.totals.screenshots = screenshots.length;
    mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, "browser-metrics.json");
    try {
      writeFileSync(reportPath, `${JSON.stringify(metrics, null, 2)}\n`);
      console.log(`metrics: ${reportPath}`);
      console.log(`screenshots: ${screenshotDir} (${screenshots.length} files)`);
    } catch (error) {
      console.error(`could not write metrics: ${error.message}`);
    }
    console.log(
      `checks: ${metrics.totals.checks}, failures: ${metrics.totals.failures}, page loads: ${metrics.totals.pageLoads}`,
    );
    if (browser) await browser.close().catch(() => {});
    await new Promise((resolve) => server.close(resolve));
  }
}

const watchdog = setTimeout(() => {
  console.error(`watchdog: ${deadlineMs} ms budget exceeded; partial results are in ${reportDir}`);
  const reportPath = path.join(reportDir, "browser-metrics.json");
  try {
    mkdirSync(reportDir, { recursive: true });
    writeFileSync(reportPath, `${JSON.stringify({ ...metrics, aborted: "watchdog" }, null, 2)}\n`);
  } catch {
    // reporting is best effort on the way out
  }
  process.exit(1);
}, deadlineMs);

let exitCode = 2;
try {
  exitCode = await main();
} catch (error) {
  if (error instanceof EnvironmentProblem) {
    console.error(`environment: ${error.message}`);
    exitCode = 2;
  } else {
    console.error(`unexpected failure: ${error?.stack ?? error}`);
    exitCode = 1;
  }
} finally {
  clearTimeout(watchdog);
}
process.exit(exitCode);
