import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { UsageToolWindow } from "./usage-tool-window";

/**
 * The window owns three tabs and opens on the token statistics.
 *
 * The host reads are unavailable under this DOM, so each view renders its own
 * empty or failing state. What this protects is the tab bar really belonging to
 * the panel and the switch replacing the visible view, which is where the
 * layout regression lived.
 */
test("the usage tool window opens on the token statistics and switches tabs", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const translator = createTranslator("en-US");
  const container = document.createElement("div");
  let root: Root | undefined;

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;

    await act(async () => {
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <UsageToolWindow onClose={() => undefined} />
        </LocaleProvider>,
      );
    });

    // The range selector inside the token view is a second tab list, so every
    // query below stays scoped to the window's own tab bar.
    const tabBar = container.querySelector('[data-slot="tabs-list"]');
    expect(tabBar).not.toBeNull();
    const tabs = [...(tabBar?.querySelectorAll('[role="tab"]') ?? [])];
    expect(tabs.map((tab) => tab.textContent)).toEqual([
      translator("usageStats.tab.quota"),
      translator("usageStats.tab.tokens"),
      translator("usageStats.tab.log"),
    ]);

    const selectedTab = () => tabBar?.querySelector('[role="tab"][aria-selected="true"]');
    expect(selectedTab()?.textContent).toBe(translator("usageStats.tab.tokens"));
    expect(container.textContent).toContain(translator("usageStats.range.today"));

    await act(async () => {
      (tabs[0] as HTMLElement | undefined)?.click();
    });

    expect(selectedTab()?.textContent).toBe(translator("usageStats.tab.quota"));
    // The token view is replaced rather than stacked under the quota view.
    expect(container.textContent).not.toContain(translator("usageStats.range.today"));
  } finally {
    if (root) {
      act(() => root?.unmount());
    }
    container.remove();
    restoreDom();
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});
