import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";
import { voidMarkdown } from "@void/md/plugin";
import { voidReact } from "@void/react/plugin";
import tailwindcss from "@tailwindcss/vite";

const rootDir = dirname(fileURLToPath(import.meta.url));
const API_LAST_UPDATED_ID = "virtual:api-last-updated";
const RESOLVED_API_LAST_UPDATED_ID = `\0${API_LAST_UPDATED_ID}`;
const apiMarkdownFiles = [
  ["overview", "overview.md"],
  ["conversion-model", "conversion-model.md"],
  ["module-registration", "module-registration.md"],
  ["build-openharmony", "build-openharmony.md"],
  ["build-node", "build-node.md"],
  ["declaration-generation", "declaration-generation.md"],
  ["dts-overrides", "dts-overrides.md"],
  ["versioning", "versioning.md"],
  ["values-primitives", "values-primitives.md"],
  ["values-objects", "values-objects.md"],
  ["binary-data", "binary-data.md"],
  ["callback-functions", "callback-functions.md"],
  ["async-runtime", "async-runtime.md"],
  ["classes-ownership", "classes-ownership.md"],
  ["errors-results", "errors-results.md"],
] as const;

function apiFallback(): Plugin {
  return {
    name: "api-subpath-fallback",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        if (req.url?.startsWith("/api/") && !req.url.includes(".")) req.url = "/api/index.html";
        next();
      });
    },
    configurePreviewServer(server) {
      server.middlewares.use((req, _res, next) => {
        if (req.url?.startsWith("/api/") && !req.url.includes(".")) req.url = "/api/index.html";
        next();
      });
    },
  };
}

function apiLastUpdated(): Plugin {
  return {
    name: "api-last-updated",
    resolveId(id) {
      return id === API_LAST_UPDATED_ID ? RESOLVED_API_LAST_UPDATED_ID : null;
    },
    load(id) {
      if (id !== RESOLVED_API_LAST_UPDATED_ID) return null;

      const updated = Object.fromEntries(
        apiMarkdownFiles.map(([sectionId, file]) => {
          const filePath = resolve(rootDir, "src/content/api", file);
          return [sectionId, lastUpdatedIso(filePath)];
        }),
      );

      return `export const lastUpdatedByApiSection = ${JSON.stringify(updated, null, 2)};`;
    },
  };
}

function lastUpdatedIso(filePath: string) {
  try {
    const committed = execFileSync("git", ["log", "-1", "--format=%cI", "--", filePath], {
      cwd: rootDir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (committed) return committed;
  } catch {
    // Untracked files have no git history yet; fall back to filesystem time.
  }

  return statSync(filePath).mtime.toISOString();
}

export default defineConfig({
  plugins: [
    voidReact(),
    voidMarkdown({
      shiki: {
        themes: {
          light: "github-light",
          dark: "github-dark",
        },
      },
    }),
    apiFallback(),
    apiLastUpdated(),
    tailwindcss(),
  ],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(rootDir, "index.html"),
        api: resolve(rootDir, "api/index.html"),
      },
    },
  },
});
