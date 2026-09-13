import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Last-modified date per API document, resolved once per build.
 *
 * A single `git log` pass covers the whole directory instead of spawning a
 * process per file, and the result is cached for the rest of the build.
 * Shallow checkouts fall back to filesystem mtime, and a build never fails
 * because history is unavailable — CI checks out full history, see
 * .github/workflows/website.yml.
 */

let cache: Map<string, string> | null = null;

/** Maps a document id to an ISO 8601 commit (or file) timestamp. */
export function lastUpdatedByDoc(): Map<string, string> {
  cache ??= collect();
  return cache;
}

function collect(): Map<string, string> {
  const result = new Map<string, string>();
  const dir = locateApiDir();
  if (!dir) return result;

  const committed = committedDates(dir);
  for (const file of readdirSync(dir)) {
    if (!file.endsWith(".md")) continue;
    const date = committed.get(file) ?? modifiedAt(path.join(dir, file));
    if (date) result.set(file.replace(/\.md$/, ""), date);
  }

  return result;
}

/**
 * Finds `src/content/api`. The first candidate covers local builds; the
 * others keep working if the module is bundled somewhere `import.meta.url`
 * no longer points at the sources.
 */
function locateApiDir(): string | null {
  const candidates = [
    fileURLToPath(new URL("../content/api/", import.meta.url)),
    path.resolve(process.cwd(), "src/content/api"),
    path.resolve(process.cwd(), "website/src/content/api"),
  ];
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

function committedDates(dir: string): Map<string, string> {
  const dates = new Map<string, string>();

  let output: string;
  try {
    output = execFileSync(
      "git",
      ["log", "--format=%x00%cI", "--name-only", "--relative", "--", "."],
      {
        cwd: dir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      },
    );
  } catch {
    return dates;
  }

  let current = "";
  for (const line of output.split("\n")) {
    if (line.startsWith("\0")) {
      current = line.slice(1).trim();
      continue;
    }
    const name = line.trim();
    // `git log` is newest-first, so the first hit for a path is its last change.
    if (name && current && !dates.has(name)) dates.set(name, current);
  }

  return dates;
}

function modifiedAt(file: string): string {
  try {
    return statSync(file).mtime.toISOString();
  } catch {
    return "";
  }
}
