import "@fontsource/maple-mono/index.css";
import { StrictMode, useMemo, useState, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import { ApiDocsPage } from "./api-docs";
import InstallSnippet from "./content/snippets/install.md";
import NodeSnippet from "./content/snippets/node.md";
import OpenHarmonySnippet from "./content/snippets/openharmony.md";
import TypesSnippet from "./content/snippets/types.md";
import { siteHref, siteRelativePath } from "./site-paths";
import "./styles.css";

type Snippet = {
  id: string;
  label: string;
  language: string;
  code: string;
  Component: ComponentType;
};

type SiteRoute = "home" | "api";

const snippets: Snippet[] = [
  {
    id: "install",
    label: "ZON install",
    language: "zon",
    Component: InstallSnippet,
    code: `.{
    .name = "appname",
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"zig-napi" = .{
            .url = "https://github.com/openharmony-zig/zig-napi/archive/refs/tags/<GIT_TAG>.tar.gz",
            .hash = "HASH_GOES_HERE",
        },
    },
}`,
  },
  {
    id: "openharmony",
    label: "OpenHarmony",
    language: "zig",
    Component: OpenHarmonySnippet,
    code: `const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");

    _ = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .napi_module = napi,
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
}`,
  },
  {
    id: "node",
    label: "Node addon",
    language: "zig",
    Component: NodeSnippet,
    code: `const addon = try napi_build.nodeAddonBuild(b, .{
    .name = "hello",
    .napi_module = napi,
    .node_api = .{
        .version = .v8,
        .experimental = false,
    },
    .root_module_options = .{
        .root_source_file = b.path("./src/hello.zig"),
        .target = target,
        .optimize = optimize,
    },
});
_ = addon;`,
  },
  {
    id: "types",
    label: "Type definitions",
    language: "zig",
    Component: TypesSnippet,
    code: `const dts = try napi_build.generateTypeDefinition(b, .{
    .root_source_file = b.path("./src/hello.zig"),
    .output = b.path("index.d.ts"),
    .napi_module = napi,
});
b.getInstallStep().dependOn(&dts.step);`,
  },
];

const capabilities = [
  {
    title: "Dual runtime output",
    body: "Use one Zig export surface to build OpenHarmony shared libraries and Node.js addons.",
  },
  {
    title: "Typed JavaScript boundary",
    body: "Generate declaration files from functions, classes, enums, async descriptors, structs, and unions.",
  },
  {
    title: "N-API version gates",
    body: "Select Node-API v4 through v10 behavior and fail early when wrappers need a newer runtime API.",
  },
  {
    title: "Low-level escape hatches",
    body: "Work directly with Object, String, Buffer, ArrayBuffer, TypedArray, DataView, External, and references.",
  },
];

const surfaces = [
  ["OpenHarmony", "aarch64-linux-ohos, arm-linux-ohoseabi, x86_64-linux-ohos"],
  ["Node.js", "host target by default, with platform-specific .node output names"],
  ["TypeScript", "index.d.ts generation from the same addon root"],
  ["Examples", "basic, init, node, allocator, memory, and benchmark fixtures"],
];

function App() {
  const route = resolveRoute();

  if (route === "api") {
    return (
      <>
        <SiteHeader route={route} />
        <main id="top">
          <ApiDocsPage />
        </main>
        <SiteFooter />
      </>
    );
  }

  return <HomePage route={route} />;
}

function resolveRoute(): SiteRoute {
  const path = siteRelativePath();
  return path === "api" || path.startsWith("api/") ? "api" : "home";
}

function HomePage({ route }: { route: SiteRoute }) {
  const [activeSnippetId, setActiveSnippetId] = useState(snippets[0]?.id ?? "");
  const [copyLabel, setCopyLabel] = useState("Copy");
  const activeSnippet = useMemo(
    () => snippets.find((snippet) => snippet.id === activeSnippetId) ?? snippets[0],
    [activeSnippetId],
  );

  async function copySnippet() {
    if (!activeSnippet) return;

    try {
      await navigator.clipboard.writeText(activeSnippet.code);
      setCopyLabel("Copied");
    } catch {
      setCopyLabel("Select");
    }

    window.setTimeout(() => setCopyLabel("Copy"), 1200);
  }

  return (
    <>
      <SiteHeader route={route} />
      <main id="top">
        <Hero />
        <CapabilitySection />
        <InstallSection />
        <BuildSection
          activeSnippet={activeSnippet}
          activeSnippetId={activeSnippetId}
          copyLabel={copyLabel}
          onCopy={copySnippet}
          onSnippetChange={setActiveSnippetId}
        />
        <TypesSection />
        <SurfaceSection />
        <ApiOverviewSection />
      </main>
      <SiteFooter />
    </>
  );
}

function SiteHeader({ route }: { route: SiteRoute }) {
  const apiClass = `transition-colors hover:text-(--color-fg)${route === "api" ? " text-(--color-fg)" : ""}`;

  return (
    <header className="site-header sticky top-0 z-50 border-b border-(--color-border)">
      <div className="container-page flex h-14 items-center justify-between gap-4">
        <a
          className="flex shrink-0 items-center gap-2.5 text-sm font-semibold text-(--color-fg)"
          href={siteHref()}
        >
          <img className="size-7 rounded-md" src={siteHref("logo/icon-256.png")} alt="" />
          zig-napi
        </a>
        <div className="ml-auto flex items-center justify-end gap-5">
          <nav
            className="flex items-center gap-5 text-sm text-(--color-muted)"
            aria-label="Primary navigation"
          >
            <a className={apiClass} href={siteHref("api/")}>
              API
            </a>
          </nav>
          <a
            className="rounded-lg border border-(--color-border-strong) px-3 py-1.5 text-sm text-(--color-muted) transition-colors hover:border-(--color-accent) hover:text-(--color-fg)"
            href="https://github.com/openharmony-zig/zig-napi"
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </a>
        </div>
      </div>
    </header>
  );
}

function Hero() {
  return (
    <section className="relative min-h-[calc(100vh-3.5rem)] overflow-hidden">
      <div className="accent-glow" aria-hidden="true" />
      <div className="container-page grid min-h-[calc(100vh-3.5rem)] items-center gap-12 py-16 lg:grid-cols-[0.9fr_1.1fr]">
        <div className="reveal is-visible">
          <img
            className="mb-7 size-16 rounded-2xl border border-(--color-border-strong)"
            src={siteHref("logo/icon-512.png")}
            alt=""
          />
          <p className="eyebrow">OpenHarmony and Node.js native addons</p>
          <h1 className="mt-5 max-w-3xl text-(--text-display-xl) font-semibold leading-[1.02] text-(--color-fg)">
            zig-napi
          </h1>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-(--color-muted)">
            Build N-API modules with Zig, ship OpenHarmony artifacts, compile Node.js addons, and
            generate TypeScript declarations from the same exported surface.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <a className="btn-primary" href="#install">
              Start with ZON
            </a>
            <a className="btn-secondary" href={siteHref("api/")}>
              API Reference
            </a>
          </div>
        </div>
        <figure className="reveal is-visible overflow-hidden rounded-lg border border-(--color-border-strong) bg-(--color-surface-1)/80 shadow-2xl shadow-black/30">
          <img
            className="block w-full"
            src={siteHref("zig-napi-pipeline.svg")}
            alt="Zig source flowing through zig-napi into OpenHarmony libraries, Node addons, and TypeScript definitions"
          />
        </figure>
      </div>
    </section>
  );
}

function CapabilitySection() {
  return (
    <section className="section-band">
      <div className="container-page">
        <SectionHeader eyebrow="Capability map" title="One addon surface, multiple outputs" />
        <div className="mt-9 grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          {capabilities.map((item) => (
            <article className="panel min-h-42" key={item.title}>
              <h3 className="text-lg font-semibold text-(--color-fg)">{item.title}</h3>
              <p className="mt-3 text-sm leading-6 text-(--color-muted)">{item.body}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function InstallSection() {
  return (
    <section id="install" className="section-band">
      <div className="container-page grid gap-10 lg:grid-cols-[0.85fr_0.55fr] lg:items-end">
        <div>
          <SectionHeader eyebrow="Setup" title="Install as a Zig package" />
          <p className="mt-5 max-w-2xl leading-7 text-(--color-muted)">
            The package exports both the <code>napi</code> module and the <code>napi_build</code>{" "}
            helpers used by examples in this repository.
          </p>
        </div>
        <div className="grid gap-3" role="list" aria-label="Setup commands">
          <code className="command-line" role="listitem">
            zig fetch
          </code>
          <code className="command-line" role="listitem">
            zig build
          </code>
          <code className="command-line" role="listitem">
            zig build -Dtarget=aarch64-linux-ohos
          </code>
        </div>
      </div>
    </section>
  );
}

type BuildSectionProps = {
  activeSnippet: Snippet | undefined;
  activeSnippetId: string;
  copyLabel: string;
  onCopy: () => void;
  onSnippetChange: (id: string) => void;
};

function BuildSection({
  activeSnippet,
  activeSnippetId,
  copyLabel,
  onCopy,
  onSnippetChange,
}: BuildSectionProps) {
  const ActiveSnippet = activeSnippet?.Component;

  return (
    <section id="build" className="section-band">
      <div className="container-page">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <SectionHeader eyebrow="Build recipes" title="Copy the shape that matches your target" />
          <div className="flex flex-wrap gap-2" role="tablist" aria-label="Build recipe snippets">
            {snippets.map((snippet) => (
              <button
                className={`snippet-tab${snippet.id === activeSnippetId ? " active" : ""}`}
                key={snippet.id}
                onClick={() => onSnippetChange(snippet.id)}
                role="tab"
                type="button"
                aria-selected={snippet.id === activeSnippetId}
              >
                {snippet.label}
              </button>
            ))}
          </div>
        </div>
        <div className="mt-7 overflow-hidden rounded-xl border border-(--color-border-strong) bg-(--color-surface-2)">
          <div className="flex h-12 items-center justify-between border-b border-(--color-border) px-4 text-xs text-(--color-faint)">
            <span>{activeSnippet?.language}</span>
            <button className="copy-button" onClick={onCopy} type="button">
              {copyLabel}
            </button>
          </div>
          <div className="void-md snippet-markdown">{ActiveSnippet ? <ActiveSnippet /> : null}</div>
        </div>
      </div>
    </section>
  );
}

function TypesSection() {
  return (
    <section id="types" className="section-band">
      <div className="container-page">
        <SectionHeader
          eyebrow="Type generation"
          title="TypeScript declarations stay close to Zig exports"
        />
        <div className="mt-9 grid gap-8 md:grid-cols-2">
          <div className="border-l-2 border-(--color-accent) pl-5">
            <h3 className="text-lg font-semibold text-(--color-fg)">Generated from Zig</h3>
            <p className="mt-3 leading-7 text-(--color-muted)">
              Functions, classes, tuples, structs, enums, arrays, unions, async descriptors, and raw
              N-API wrappers are mapped into declaration files during the build.
            </p>
          </div>
          <div className="border-l-2 border-(--color-accent) pl-5">
            <h3 className="text-lg font-semibold text-(--color-fg)">
              Override when the public contract differs
            </h3>
            <p className="mt-3 leading-7 text-(--color-muted)">
              <code>napi.dts(value, "TypeScriptType")</code> and{" "}
              <code>napi.Dts(T, "TypeScriptType")</code> let exported declarations express a custom
              TypeScript-facing contract while keeping runtime values unchanged.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

function SurfaceSection() {
  return (
    <section className="section-band">
      <div className="container-page">
        <SectionHeader eyebrow="Targets" title="Build surface" />
        <div className="mt-8 overflow-hidden rounded-xl border border-(--color-border-strong)">
          {surfaces.map(([name, detail]) => (
            <div
              className="grid border-b border-(--color-border) last:border-b-0 md:grid-cols-[220px_1fr]"
              key={name}
              role="row"
            >
              <div
                className="bg-(--color-surface-1) px-5 py-4 font-semibold text-(--color-fg)"
                role="cell"
              >
                {name}
              </div>
              <div className="px-5 pb-4 pt-0 text-(--color-muted) md:py-4" role="cell">
                {detail}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function ApiOverviewSection() {
  return (
    <section className="section-band">
      <div className="container-page grid gap-8 lg:grid-cols-[0.75fr_0.5fr] lg:items-center">
        <div>
          <SectionHeader eyebrow="Reference" title="API docs live on their own path" />
          <p className="mt-5 max-w-2xl leading-7 text-(--color-muted)">
            The standalone API reference covers module registration, build helpers, runtime values,
            binary wrappers, async descriptors, native ownership, errors, and custom TypeScript
            declaration overrides.
          </p>
        </div>
        <div className="panel">
          <p className="text-sm leading-6 text-(--color-muted)">
            Use the API page when you need exact Zig signatures and wrapper behavior instead of the
            overview flow.
          </p>
          <a className="btn-primary mt-5 w-full" href={siteHref("api/")}>
            Open API Reference
          </a>
        </div>
      </div>
    </section>
  );
}

function SectionHeader({ eyebrow, title }: { eyebrow: string; title: string }) {
  return (
    <div className="max-w-3xl">
      <p className="eyebrow">{eyebrow}</p>
      <h2 className="mt-4 text-(--text-h2) font-semibold leading-[1.1] text-(--color-fg)">
        {title}
      </h2>
    </div>
  );
}

function SiteFooter() {
  return (
    <footer className="border-t border-(--color-border)">
      <div className="container-page flex flex-col gap-3 py-8 text-sm text-(--color-faint) md:flex-row md:justify-between">
        <span>MIT licensed</span>
        <span>Inspired by napi-rs and node-addon-api</span>
      </div>
    </footer>
  );
}

const app = document.querySelector("#app");

if (!app) {
  throw new Error("Missing #app root");
}

createRoot(app).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
