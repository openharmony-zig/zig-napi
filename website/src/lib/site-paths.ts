import { joinBasePath, normalizeBasePath } from "./base-path";

/**
 * Base path the site is served from. Astro always exposes `BASE_URL` with a
 * trailing slash, so `withBase` can concatenate directly.
 */
export const basePath = normalizeBasePath(import.meta.env.BASE_URL);

/** Builds a site-absolute URL for a repository-relative path. */
export function withBase(path = ""): string {
  return joinBasePath(basePath, path);
}

/** Route of an API document; the overview is served at `/api/` itself. */
export function apiHref(id: string): string {
  return id === "overview" ? withBase("api/") : withBase(`api/${id}/`);
}
