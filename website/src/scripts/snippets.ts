/**
 * Progressive enhancement for the build-recipe snippets.
 *
 * The markup is authored as four readable code blocks with anchor links, so
 * the section works with JavaScript disabled. When this module runs it
 * upgrades the same markup into an ARIA tab widget (roving tabindex, arrow
 * keys, Home/End), reveals the copy buttons, and keeps the selected recipe in
 * sync with the URL fragment. Copying reads the code that was rendered into
 * the page; no snippet text is duplicated in JavaScript.
 */

const FEEDBACK_MS = 2400;
const COPY_LABEL = "Copy";

export function initSnippets(): void {
  const root = document.querySelector<HTMLElement>("[data-snippets]");
  if (!root) return;

  const tablist = root.querySelector<HTMLElement>("[data-snippets-tabs]");
  const tabs = Array.from(root.querySelectorAll<HTMLAnchorElement>("[data-snippet-tab]"));
  const panels = Array.from(root.querySelectorAll<HTMLElement>("[data-snippet-panel]"));
  if (!tablist || tabs.length === 0 || panels.length === 0) return;

  const panelIdOf = (tab: HTMLAnchorElement) => `build-${tab.dataset.snippetTab ?? ""}`;

  /**
   * The single place a recipe becomes the selected one. Every entry point —
   * pointer, keyboard, initial load, fragment change — goes through here, so
   * the panels, the tab state, and the URL can never disagree. Only user
   * interaction writes the fragment: on load and on `hashchange` the URL is
   * already the source of truth, and rewriting it would add history noise.
   */
  const select = (
    activeTab: HTMLAnchorElement,
    options: { moveFocus?: boolean; updateUrl?: boolean } = {},
  ) => {
    for (const tab of tabs) {
      const selected = tab === activeTab;
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", String(selected));
      tab.classList.toggle("is-active", selected);
      tab.tabIndex = selected ? 0 : -1;
    }

    for (const panel of panels) {
      panel.setAttribute("role", "tabpanel");
      panel.hidden = panel.id !== panelIdOf(activeTab);
    }
    // The tab already names the panel, so the repeated in-panel title goes away.
    for (const title of root.querySelectorAll<HTMLElement>(".snippet-title")) {
      title.hidden = true;
    }

    if (options.moveFocus) activeTab.focus();
    if (options.updateUrl) {
      // Keeps the fragment pointing at the visible recipe without scrolling.
      window.history.replaceState(null, "", `#${panelIdOf(activeTab)}`);
    }
  };

  const tabForFragment = (fragment: string) => tabs.find((tab) => panelIdOf(tab) === fragment);

  const selectFromFragment = () => {
    const tab = tabForFragment(decodeFragment(window.location.hash));
    if (tab) select(tab);
  };

  tablist.setAttribute("role", "tablist");
  root.classList.add("is-tabs");
  select(tabForFragment(decodeFragment(window.location.hash)) ?? tabs[0]);

  tablist.addEventListener("keydown", (event) => {
    const current = tabs.indexOf(document.activeElement as HTMLAnchorElement);
    if (current < 0) return;

    let next: number;
    switch (event.key) {
      case "ArrowLeft":
        next = (current - 1 + tabs.length) % tabs.length;
        break;
      case "ArrowRight":
        next = (current + 1) % tabs.length;
        break;
      case "Home":
        next = 0;
        break;
      case "End":
        next = tabs.length - 1;
        break;
      default:
        return;
    }

    event.preventDefault();
    select(tabs[next], { moveFocus: true, updateUrl: true });
  });

  for (const tab of tabs) {
    tab.addEventListener("click", (event) => {
      event.preventDefault();
      select(tab, { moveFocus: true, updateUrl: true });
    });
  }

  // A fragment typed or pasted into the address bar still selects its recipe.
  window.addEventListener("hashchange", selectFromFragment);

  // The copies only become available once the enhancement above has run.
  for (const button of root.querySelectorAll<HTMLButtonElement>("[data-snippet-copy]")) {
    button.hidden = false;
  }

  for (const button of root.querySelectorAll<HTMLButtonElement>("[data-snippet-copy]")) {
    let timer: number | undefined;

    const reset = () => {
      window.clearTimeout(timer);
      button.textContent = COPY_LABEL;
      const status = statusFor(button);
      if (status) status.textContent = "";
    };

    button.addEventListener("click", async () => {
      const code = button.closest<HTMLElement>("[data-snippet-panel]")?.querySelector("pre code");
      const status = statusFor(button);
      window.clearTimeout(timer);

      let label: string;
      let message: string;

      if (!code?.textContent?.trim()) {
        label = COPY_LABEL;
        message = "Nothing to copy here.";
      } else {
        try {
          await navigator.clipboard.writeText(code.textContent);
          label = "Copied";
          message = "Copied to clipboard.";
        } catch {
          // Report the failure honestly; the code stays visible and selectable.
          label = "Copy failed";
          message = "Copy failed. Select the code above and copy it manually.";
        }
      }

      button.textContent = label;
      if (status) status.textContent = message;
      timer = window.setTimeout(reset, FEEDBACK_MS);
    });

    window.addEventListener("pagehide", reset);
  }
}

function decodeFragment(hash: string): string {
  const raw = hash.replace(/^#/, "");
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

function statusFor(button: HTMLElement): HTMLElement | null {
  return (
    button
      .closest<HTMLElement>("[data-snippet-panel]")
      ?.querySelector<HTMLElement>("[data-snippet-status]") ?? null
  );
}
