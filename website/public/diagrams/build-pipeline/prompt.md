# Build pipeline · redraw brief

Live twin: `website/src/components/BuildPipeline.astro` (styled by
`website/src/styles/kami.css`, section "Build pipeline"). This directory is the
maintained trio: `index.html` (source), `index.png` (re-exported after every
content change, 2400px wide), `prompt.md` (this file). Edit the component first,
mirror the change here, re-export the PNG — never redraw from memory and never
edit the PNG by hand.

## Must preserve

- **This is an overview, not a tutorial.** The home page figure carries the
  shape of the pipeline only; build commands, options, flags, memory numbers
  and runtime behavior live in the guides it links to.
- **One shared root.** A single Zig addon root (`src/hello.zig`) registers the
  export surface; the root card states that and nothing more.
- **Separately configured targets, stated as such.** Each route names its own
  helper or target and its own artifact. The caption says the targets are
  configured separately; it must not claim that no command could ever produce
  several artifacts (a custom `build.zig` can wire more than one step).
- **OpenHarmony** — `napi_build.nativeAddonBuild` producing `libhello.so`.
- **Node.js** — `napi_build.nodeAddonBuild` producing
  `hello.<platform-arch-abi>.node`.
- **WASI, two flavors** — `wasm32-wasi target`, with both artifacts:
  `hello.wasm32-wasip1.wasm` marked "Unshared · no workers" and
  `hello.wasm32-wasi.wasm` marked "Shared · worker pool". The single-threaded
  flavor really is worker-free; the threaded one gets its parallelism from the
  emnapi JavaScript worker pool (`src/build/napi-build.zig`, `WasiFlavor`;
  `asyncWorkPoolSize`).
- **Declarations are a separate step** — `napi_build.generateTypeDefinition`
  writes `index.d.ts`; the caption says declarations come from the same root
  file.
- **Guide links stay real**: `/api/build-openharmony/`, `/api/build-node/`,
  `/api/wasm-runtime/`, `/api/declaration-generation/`. The live component
  builds them with `apiHref` (base-aware); the standalone page uses relative
  `../../api/.../` links so it resolves under a domain root and under a
  repository sub-path alike.
- **Tokens**: parchment `#f5f4ed`, ivory `#faf9f5`, ink-blue `#1B365D` as the
  only accent (artifact names and links), warm grays for everything else, thin
  `#d8d5c8` / `#e5e3d8` rules, serif for names (17px), `--latin-ui` and mono at
  12.5px for helpers, flavors and links. No shadow, gradient, tick, pill, or
  decorative icon.
- **Scale**: the figure stays under ~550px tall at 1280px and ~900px at 320px,
  with no font below 12px and no horizontal scroll at 320px. Compactness comes
  from cutting copy, never from shrinking type.

## Suggested additions

- Anything added here first has to earn its place against the scale budget
  above; every item below is detail the WASM guide owns today.
- Loader file names per flavor (`<binary>.wasip1.cjs`, and `<binary>.wasi.cjs`
  plus worker files for the threaded build) if the WASI lane ever gains a third
  line.
- The emnapi archive pin (`emnapi 2.0.0-alpha.5` prerelease,
  `libemnapi-basic-napi-rs.a`) and the `@emnapi/core` plugin note.
- The deferred single-threaded ESM binding (`<binary>.wasip1-deferred.js`,
  `instantiate()` / `createInstance()` / `dispose()`).
- Node-API version gates (`node_api.version`, v4–v10) as a shared-root note —
  only if the root card ever gains a second line of facts.

## Visual direction

- Keep the reading path: shared root on the left, the three routes branching off
  one rail to the right, the declaration step closing the figure under its own
  rule.
- Hierarchy stays with type and spacing: name (serif 17px) → helper or target
  label (mono, stone, one line) → artifact (mono, ink-blue) with its flavor note
  (12.5px UI sans, stone) → guide link (12.5px UI sans). Do not add a second
  accent, a fill behind the lanes, or an extra tier of small type.
- Keep the root card a single quiet ivory fill with no border; the lanes are
  separate by rules and space only.
- Lanes are three columns (name and helper, artifacts, guide) while the page is
  wider than 1020px; below that they stack into one column so a file name is
  never split mid-token. The flow itself stacks below 880px.
- If the figure grows past roughly five rows, split it or cut a fact; do not
  shrink type or padding.
- The standalone page is a fixed export canvas (976px of diagram inside two
  112px safe margins, captured at 2x); the responsive rules above live in the
  live component and `kami.css`, not in the export.

## Sister boundaries

- `website/src/pages/index.astro` section 05 "Build surface" owns the target and
  option table; the figure does not repeat target triples or option lists.
- `src/content/api/build-openharmony.md`, `build-node.md`, `wasm-runtime.md` and
  `declaration-generation.md` own the build commands, option tables, memory
  numbers, cancellation and troubleshooting detail. The figure links to them and
  stops there — no command line, no flag list, no plugin prose.
- `src/content/snippets/*.md` (the home page build recipes) own copy-paste
  build files.
- `public/zig-napi-pipeline.svg` is the retired bitmap-era artwork. It is no
  longer referenced by the home page; do not restore it, and do not merge its
  dark or orange palette into this figure.
