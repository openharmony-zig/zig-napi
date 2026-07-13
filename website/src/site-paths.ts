const siteBasePath = import.meta.env.BASE_URL;

export function siteHref(path = "") {
  return `${siteBasePath}${path.replace(/^\/+/, "")}`;
}

export function siteRelativePath(pathname = window.location.pathname) {
  const relativePath = pathname.startsWith(siteBasePath)
    ? pathname.slice(siteBasePath.length)
    : pathname;

  return relativePath.replace(/^\/+|\/+$/g, "");
}
