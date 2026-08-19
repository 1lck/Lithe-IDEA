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
    expect(iconEntries).toHaveLength(203);
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
    ];
    for (const exportName of mapped) {
      const markup = renderIcon(AppIcons[exportName] as ElementType);
      expect(markup).toContain("lithe-idea-icon");
      expect(markup.match(/<img/g)?.length).toBe(2);
      expect(markup).toContain("lithe-idea-icon-light");
      expect(markup).toContain("lithe-idea-icon-dark");
    }
  });

  test("forwards title to the visible asset alt text", () => {
    const markup = renderToStaticMarkup(
      createElement(AppIcons.TrashIcon as ElementType, { title: "delete action" }),
    );
    expect(markup).toContain('alt="delete action"');
  });
});
