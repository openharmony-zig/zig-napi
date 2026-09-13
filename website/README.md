# zig-napi documentation site

Static site for the zig-napi API reference, built with [Astro](https://astro.build)
(`7.3.2`, Node `>=22.12.0`). The pages are generated at build time: the API
documents ship as complete HTML, and JavaScript is only used to enhance the
build-recipe switcher on the landing page.

## Commands

Run from the repository root (`pnpm run website:<script>`) or from `website/`
(`pnpm run <script>`).

| Script | Command | Purpose |
| --- | --- | --- |
| `dev` | `astro dev --host 127.0.0.1` | Local dev server |
| `check` | `astro check` | Type and template diagnostics |
| `build` | `astro check && astro build` | Production build into `website/dist` |
| `preview` | `astro preview --host 127.0.0.1` | Serve the built output |
| `format` | `prettier --write "src/**/*.astro"` | Format `.astro` files |
| `test` | `node --test test/static.test.mjs` | Static acceptance tests over `dist` |
| `test:browser` | `node test/browser.mjs` | Real-browser acceptance (Playwright) |

```bash
# from the repository root
pnpm run website:build          # astro check + build
pnpm run website:test           # static acceptance tests over website/dist
pnpm run website:test:browser   # Chromium acceptance; needs a browser (see below)
pnpm run website:preview        # serve website/dist at http://127.0.0.1:4321
```

`astro check` is part of `build`, so a type error fails the build.

### Formatting

The workspace formatter (`oxk`) does not parse `.astro` files, so the `.astro`
sources are formatted with `prettier` + `prettier-plugin-astro`
(`pnpm run format:astro`, run from the root). `oxk` still formats the TypeScript
under `website/src` and `website/astro.config.ts` through the root `format:js`
script.

`format:js` passes `--exclude "**/content/**"`: `oxk` also rewrites Markdown
(among other things it normalises `*emphasis*` to `_emphasis_`), and the
published documents under `src/content/` are copy, not source to be reformatted.

### Browser tests

`test:browser` drives a real Chromium through `playwright-core`. A browser
binary is required:

```bash
# one-time, downloads Chromium into the Playwright cache
pnpm --filter zig-napi-website exec playwright-core install --with-deps chromium

# or point the harness at an existing Chrome/Chromium
CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" pnpm run website:test:browser
```

The harness serves the freshly built `dist/` with its own static server; it does
not need a running dev server. `WEBSITE_SCREENSHOT_DIR` optionally writes the
375px/1280px captures it takes.

## Deployment path (`base`)

Routes and asset URLs are all built from one base path helper
(`src/lib/base-path.ts`), so the site works both at a domain root and under a
repository sub-path:

```bash
# served from "/"
pnpm run website:build
pnpm run website:test
pnpm run website:test:browser

# served from "/zig-napi/" — every command needs the same value
SITE_BASE_PATH=/zig-napi/ pnpm run website:build
SITE_BASE_PATH=/zig-napi/ pnpm run website:test
SITE_BASE_PATH=/zig-napi/ pnpm run website:test:browser

# any nested path works the same way
SITE_BASE_PATH=/group/project/ pnpm run website:build
```

The value has to be passed to **all three** commands. `build` is what writes the
base into every URL, while the two test commands use it to decide which routes
and assets they expect; neither test suite infers the base from `dist/`, so a
sub-path build verified without `SITE_BASE_PATH` fails against URLs the build
never emitted.

- `SITE_BASE_PATH` accepts an empty value, `/`, `/zig-napi/`, or a nested path.
- `SITE_URL` optionally overrides the origin used for canonical URLs. It
  defaults to `https://openharmony-zig.github.io`, and the GitHub Pages
  workflow passes the repository sub-path it derives itself.

The GitHub Pages workflow (`.github/workflows/website.yml`) passes the same
`SITE_BASE_PATH` to the build, the static tests, and the browser tests, so the
artifact is verified exactly as it will be served.

## Content

The published copy is plain Markdown and is never generated or duplicated:

```
src/content/api/*.md       15 API documents (unchanged since before the migration)
src/content/snippets/*.md  4 build recipes shown on the landing page
```

`src/content.config.ts` loads them with Astro's glob loader, so each file's
frontmatter (`title`) and body are available to the pages. Editing a document
means editing its Markdown file; nothing else needs to change.

- Navigation titles, summaries, and the document order live in
  `src/data/api-docs.ts`. Sidebar order, grouping, and prev/next paging all read
  from that one module.
- Site-wide metadata (name, description, repository, license) lives in
  `src/consts.ts`.
- "Last updated" dates come from `git log` for the Markdown file, resolved once
  per build (`src/lib/last-updated.ts`) and rendered in UTC so the output does
  not depend on the build machine's timezone. Files without git history fall
  back to their filesystem modification time.

### Anchors and links

`src/lib/markdown-docs.ts` runs as a build-time Markdown plugin:

- Heading ids keep the exact slugs the previous renderer (`markdown-it-anchor`)
  produced, including percent-encoded ones such as
  `#jserror%2C-jstypeerror%2C-jsrangeerror`, so previously published fragment
  URLs keep working.
- Relative cross-document links written in the Markdown (`./classes-ownership`)
  are rewritten against the deployment base path at render time; the Markdown
  sources are not edited.
- Wide tables are wrapped so they scroll in their own region instead of
  widening the page.

Syntax highlighting happens during the build (`src/lib/kami-code-theme.ts`);
no highlighter is shipped to the browser.

## Visual system

The layout, tokens, and components are ported from the kami landing-page
template (`assets/templates/landing-page-en.html`) and kami's documentation-site
rules — warm paper (`#f5f4ed` / `#faf9f5`), a single ink-blue accent
(`#1B365D`), Charter/Georgia for text, the system UI font for labels, and mono
for code. It is a translation of an existing design, not a new theme.

- The landing page keeps the original product copy, the original logo files
  (`public/logo/`), and the original pipeline diagram
  (`public/zig-napi-pipeline.svg`) with its own colours. The diagram sits in a
  dark frame, which is the surface kami gives code and product imagery.
- The documentation shell is two columns: a 178px navigation rail with the
  in-flow "On this page" list beneath it, and a reading column capped at about
  720px. Below 880px the rail becomes a horizontally scrolling strip and the
  auxiliary list is dropped.
- Code blocks use kami's sanctioned dark code frame with its token palette.
- No framework runtime ships to the browser. The only client script is the
  build-recipe enhancement (`src/scripts/snippets.ts`), inlined on the landing
  page; the API pages contain no JavaScript at all.

## Preservation boundaries

- The 15 API documents and 4 snippets are the published copy; they are byte
  identical to the pre-migration sources and are not rewritten by the build.
- `/api/` serves the overview document; every other document is served at
  `/api/<id>/`. `/api/overview/` is kept as an alias for links published before
  the migration and points its canonical URL at `/api/`.
- Ordered lists, tables, code fences, and inline formatting render with the same
  text and indentation as before.
