import { describe, expect, test } from "bun:test";
import { createElement, type ElementType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import * as AppIcons from "./icons";

const intentionalHelpIcons = new Set(["Icon"]);

const iconEntries = Object.entries(AppIcons).filter(
  ([exportName]) => exportName === "Icon" || exportName.endsWith("Icon"),
) as Array<[string, ElementType]>;

function renderIcon(IconComponent: ElementType) {
  return renderToStaticMarkup(createElement(IconComponent));
}

describe("application icon mappings", () => {
  test("exports the complete icon inventory", () => {
    expect(iconEntries).toHaveLength(209);
  });

  test("avoids unintended help fallbacks", () => {
    const unintendedFallbacks = iconEntries
      .filter(([exportName]) => !intentionalHelpIcons.has(exportName))
      .filter(([, IconComponent]) => renderIcon(IconComponent).includes("lucide-circle-help"))
      .map(([exportName]) => exportName);

    expect(unintendedFallbacks).toEqual([]);
  });

  test("keeps intentional help exports", () => {
    for (const exportName of intentionalHelpIcons) {
      const IconComponent = AppIcons[exportName as keyof typeof AppIcons] as ElementType;
      expect(renderIcon(IconComponent)).toContain("lucide-circle-help");
    }
  });

  test("maps unmapped controls to the expected Lucide icons", () => {
    const cases: Array<[ElementType, string]> = [
      [AppIcons.WindowExpandIcon, "lucide-maximize2"],
      [AppIcons.SquareIcon, "lucide-square"],
      [AppIcons.SunIcon, "lucide-sun"],
      [AppIcons.TerminalIcon, "lucide-terminal"],
    ];

    for (const [IconComponent, expectedClass] of cases) {
      expect(renderIcon(IconComponent)).toContain(expectedClass);
    }
  });

  test("renders mapped IntelliJ icons as dual-variant image assets", () => {
    const mapped: Array<keyof typeof AppIcons> = [
      "MagnifyingGlassIcon",
      "GearIcon",
      "XIcon",
      "WarningIcon",
      "WarningCircleIcon",
      "OpenExternalIcon",
      "GitBranchIcon",
      "PlayIcon",
      "QuestionIcon",
      "FilesIcon",
      "GitGraphIcon",
      "TerminalWindowIcon",
      "MenuIcon",
      "RunToolWindowIcon",
      "ProblemsToolWindowIcon",
    ];
    for (const exportName of mapped) {
      const markup = renderIcon(AppIcons[exportName] as ElementType);
      expect(markup).toContain("<svg");
      expect(markup).toContain('viewBox="0 0 16 16"');
      expect(markup.match(/<image/g)?.length).toBe(2);
      expect(markup).toContain("lithe-idea-icon-light");
      expect(markup).toContain("lithe-idea-icon-dark");
    }
  });

  test("renders IntelliJ 20x20 toolbar artwork for large icons", () => {
    // IntelliJ's main toolbar and stripes draw dedicated @20x20 art, not the scaled 16px icon.
    const large = renderToStaticMarkup(
      createElement(AppIcons.GearIcon as ElementType, { large: true }),
    );
    expect(large).toContain('viewBox="0 0 20 20"');
    expect(large).toContain("settings@20x20");
    expect(large).not.toContain("large=");

    // Icons without 20x20 artwork keep their 16px asset.
    const fallback = renderToStaticMarkup(
      createElement(AppIcons.ChevronDownIcon as ElementType, { large: true }),
    );
    expect(fallback).toContain('viewBox="0 0 16 16"');
  });

  test("forwards title to the asset aria label", () => {
    const markup = renderToStaticMarkup(
      createElement(AppIcons.TrashIcon as ElementType, { title: "delete action" }),
    );
    expect(markup).toContain('aria-label="delete action"');
  });
});
