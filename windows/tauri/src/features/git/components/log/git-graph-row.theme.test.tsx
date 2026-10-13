import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, useMemo } from "react";
import { createRoot } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import themes from "@/extensions/themes/builtin/lithe.json";
import { toThemeDefinition } from "@/extensions/themes/theme-file";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import type { ThemeFile } from "@/extensions/themes/theme-schema";
import { layoutGitGraph } from "../../utils/git-graph-layout";
import { GitGraphRow } from "./git-graph-row";

for (const [themeId, color] of [
  ["lithe-light", "rgb(71, 161, 179)"],
  ["lithe-dark", "rgb(61, 138, 153)"],
]) {
  test(`real ${themeId} registry paints nodes and edges without requiring a dark class`, async () => {
    const restoreDom = installHappyDom();
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    const previousTheme = themeRegistry.getCurrentTheme();
    const registered: string[] = [];
    const style = document.createElement("style");
    style.textContent = readFileSync(new URL("./git-graph.css", import.meta.url), "utf8");
    document.head.append(style);
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    let layoutBuilds = 0;
    function Harness() {
      const layout = useMemo(() => {
        layoutBuilds += 1;
        return layoutGitGraph([
          {
            hash: "tip",
            shortHash: "tip",
            parentHashes: ["root"],
            message: "tip",
            author: "Fixture",
            date: "unknown",
            decorations: "HEAD -> main",
          },
          {
            hash: "root",
            shortHash: "root",
            parentHashes: [],
            message: "root",
            author: "Fixture",
            date: "unknown",
            decorations: "",
          },
        ]);
      }, []);
      return <GitGraphRow row={layout.rows[0]} showDecorations={false} />;
    }
    try {
      for (const value of (themes as ThemeFile).themes) {
        const theme = toThemeDefinition(value);
        if (!themeRegistry.getTheme(theme.id)) {
          themeRegistry.registerTheme(theme);
          registered.push(theme.id);
        }
      }
      // Happy DOM caches ancestor-selector style after first measurement.
      // Verify each actual registry mode in a fresh document; Chromium verifies
      // switching the same mounted DOM between modes without a React update.
      themeRegistry.applyTheme(themeId);
      await act(async () => root.render(<Harness />));
      expect(document.documentElement.classList.contains("dark")).toBe(false);
      expect(document.documentElement.dataset.themeType).toBe(
        themeId === "lithe-dark" ? "dark" : "light",
      );
      expect(getComputedStyle(container.querySelector("ellipse")!).color).toBe(color);
      expect(getComputedStyle(container.querySelector("path")!).color).toBe(color);
      expect(layoutBuilds).toBe(1);
    } finally {
      await act(async () => root.unmount());
      if (previousTheme) themeRegistry.applyTheme(previousTheme);
      registered.forEach((id) => themeRegistry.unregisterTheme(id));
      environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  });
}
