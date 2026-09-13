/**
 * Base path helpers.
 *
 * `SITE_BASE_PATH` may be empty (root deployment), `/`, `/zig-napi/`, or a
 * nested path such as `/org/repo/`. Everything that emits a URL — pages,
 * components, markdown link rewriting, metadata — goes through these two
 * functions so a repository sub-path never has to be special-cased.
 */

/** Normalizes any accepted value to either `/` or `/segment/.../`. */
export function normalizeBasePath(value: string | undefined | null): string {
  const trimmed = (value ?? "").trim().replace(/^\/+|\/+$/g, "");
  return trimmed ? `/${trimmed}/` : "/";
}

/** Joins a base path (any form accepted by `normalizeBasePath`) with a page path. */
export function joinBasePath(base: string, path = ""): string {
  return `${normalizeBasePath(base)}${path.replace(/^\/+/, "")}`;
}
