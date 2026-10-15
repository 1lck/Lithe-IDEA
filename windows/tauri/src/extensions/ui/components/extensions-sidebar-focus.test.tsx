import { afterAll, expect, spyOn, test } from "bun:test";
import { plugin } from "bun";
import { readFileSync } from "node:fs";
import { act } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import * as native from "@/platform/tauri-core";
import * as skills from "@/features/ai/lib/skill-library";

const restoreDom = installHappyDom();
// Bun has no Vite glob transform. Icon asset bytes are unrelated to focus behavior.
plugin({
  name: "plugin-focus-icon-assets",
  setup(build) {
    build.onLoad({ filter: /extensions-sidebar\.tsx$/ }, ({ path }) => ({
      contents: readFileSync(path, "utf8").replace(/import\.meta\.glob\([\s\S]*?\)/, "({})"),
      loader: "tsx",
    }));
  },
});
afterAll(() => {
  plugin.clearAll();
  restoreDom();
});
const { createRoot } = await import("react-dom/client");
const { ExtensionsSidebar } = await import("./extensions-sidebar");

test.each(["settings", "workbench"] as const)(
  "plugin browser preserves the expected search focus in %s",
  async (presentation) => {
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    // Mount the real browser, but keep agent discovery and the marketplace offline and bounded.
    const agents = spyOn(native, "invoke").mockResolvedValue([]);
    const marketplace = spyOn(skills, "loadMarketplaceSkills").mockResolvedValue([]);
    const globalSearch = document.createElement("input");
    const host = document.createElement("div");
    let root: Root | undefined;
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      document.body.append(globalSearch, host);
      globalSearch.focus();
      root = createRoot(host);
      const mountedRoot = root;
      await act(async () =>
        mountedRoot.render(
          <LocaleProvider language="en-US">
            {presentation === "settings" ? (
              <ExtensionsSidebar presentation="settings" />
            ) : (
              <ExtensionsSidebar />
            )}
          </LocaleProvider>,
        ),
      );
      const pluginSearch = host.querySelector<HTMLInputElement>('input:not([type="file"])');
      expect(pluginSearch).not.toBeNull();
      expect(document.activeElement).toBe(
        presentation === "settings" ? globalSearch : pluginSearch,
      );
    } finally {
      try {
        await act(async () => root?.unmount());
      } finally {
        host.remove();
        globalSearch.remove();
        agents.mockRestore();
        marketplace.mockRestore();
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      }
    }
  },
);
