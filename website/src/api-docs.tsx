import { lastUpdatedByApiSection } from "virtual:api-last-updated";
import { apiMarkdownGroups, apiMarkdownSections, getApiSection } from "./content/api";
import { siteHref, siteRelativePath } from "./site-paths";

export function ApiDocsPage() {
  const activeId = resolveActiveApiSectionId();
  const activeSection = getApiSection(activeId);
  const ActiveComponent = activeSection.Component;
  const activeIndex = apiMarkdownSections.findIndex((section) => section.id === activeSection.id);
  const previousSection = activeIndex > 0 ? apiMarkdownSections[activeIndex - 1] : undefined;
  const nextSection =
    activeIndex >= 0 && activeIndex < apiMarkdownSections.length - 1
      ? apiMarkdownSections[activeIndex + 1]
      : undefined;
  const tocHeadings = activeSection.headings.filter(
    (heading) => heading.depth > 1 && heading.depth <= 3,
  );
  const lastUpdated = formatLastUpdated(lastUpdatedByApiSection[activeSection.id]);

  return (
    <div className="container-page api-container py-12">
      <details className="mb-8 rounded-lg border border-(--color-border) bg-(--color-surface-1) md:hidden">
        <summary className="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-xs uppercase text-(--color-muted)">
          API Reference
          <span className="nav-caret text-(--color-faint)" aria-hidden="true">
            ▾
          </span>
        </summary>
        <nav className="flex flex-col gap-5 px-2 pb-3 text-sm" aria-label="API sections">
          {apiMarkdownGroups.map((group) => (
            <div className="grid gap-2" key={group.title}>
              <p className="px-2 text-xs uppercase text-(--color-faint)">{group.title}</p>
              {group.sections.map((section) => (
                <a
                  className={apiNavLinkClass(section.id === activeSection.id, "mobile")}
                  href={apiHref(section.id)}
                  key={section.id}
                >
                  {section.title}
                </a>
              ))}
            </div>
          ))}
        </nav>
      </details>
      <div className="flex gap-10 lg:gap-14">
        <aside className="hidden w-52 shrink-0 md:block">
          <nav className="sticky top-20 flex flex-col gap-7 text-sm" aria-label="API sections">
            <p className="mb-2 text-xs uppercase text-(--color-muted) opacity-60">API Reference</p>
            {apiMarkdownGroups.map((group) => (
              <div className="grid gap-3" key={group.title}>
                <p className="pl-3 text-xs uppercase text-(--color-faint)">{group.title}</p>
                {group.sections.map((section) => (
                  <a
                    className={apiNavLinkClass(section.id === activeSection.id)}
                    href={apiHref(section.id)}
                    key={section.id}
                  >
                    {section.title}
                  </a>
                ))}
              </div>
            ))}
          </nav>
        </aside>
        <main className="grid min-w-0 flex-1 grid-cols-1 gap-12 xl:grid-cols-[minmax(0,1fr)_11rem]">
          <article className="void-md api-markdown min-w-0">
            {lastUpdated ? <p className="api-last-updated">Last updated {lastUpdated}</p> : null}
            <ActiveComponent />
            <nav className="api-doc-pager" aria-label="API document navigation">
              {previousSection ? (
                <a className="api-doc-pager-link" href={apiHref(previousSection.id)}>
                  <span>Previous</span>
                  <strong>{previousSection.title}</strong>
                </a>
              ) : (
                <span />
              )}
              {nextSection ? (
                <a className="api-doc-pager-link next" href={apiHref(nextSection.id)}>
                  <span>Next</span>
                  <strong>{nextSection.title}</strong>
                </a>
              ) : (
                <span />
              )}
            </nav>
          </article>
          {tocHeadings.length > 0 ? (
            <aside className="api-toc hidden xl:block">
              <nav className="sticky top-20" aria-label="Current document sections">
                <p className="api-toc-title">On this page</p>
                <div className="api-toc-links">
                  {tocHeadings.map((heading) => (
                    <a
                      className={`api-toc-link depth-${heading.depth}`}
                      href={`#${heading.slug}`}
                      key={heading.slug}
                    >
                      {heading.text}
                    </a>
                  ))}
                </div>
              </nav>
            </aside>
          ) : null}
        </main>
      </div>
    </div>
  );
}

function resolveActiveApiSectionId() {
  const parts = siteRelativePath().split("/").filter(Boolean);
  return parts[0] === "api" && parts[1] ? parts[1] : "overview";
}

function apiHref(id: string) {
  return siteHref(id === "overview" ? "api/" : `api/${id}/`);
}

function apiNavLinkClass(active: boolean, mode: "desktop" | "mobile" = "desktop") {
  if (mode === "mobile") {
    return [
      "flex min-h-11 items-center rounded-md px-2 transition-colors",
      active
        ? "bg-(--color-accent-muted) text-(--color-fg)"
        : "text-(--color-muted) hover:bg-(--color-surface-2) hover:text-(--color-fg)",
    ].join(" ");
  }

  return [
    "border-l-2 pl-3 transition-colors",
    active
      ? "border-(--color-accent) text-(--color-fg)"
      : "border-transparent text-(--color-muted) hover:border-(--color-accent) hover:text-(--color-fg)",
  ].join(" ");
}

function formatLastUpdated(value: string | undefined) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "";

  return new Intl.DateTimeFormat("en", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(date);
}
