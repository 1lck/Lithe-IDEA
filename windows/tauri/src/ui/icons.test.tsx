import { describe, expect, test } from "bun:test";
import { createElement, type ElementType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import * as AppIcons from "./icons";

const intentionalHelpIcons = new Set(["Icon", "QuestionIcon"]);

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

  test("maps representative controls to the expected Lucide icons", () => {
    const cases: Array<[ElementType, string]> = [
      [AppIcons.FilesIcon, "lucide-files"],
      [AppIcons.MagnifyingGlassIcon, "lucide-search"],
      [AppIcons.GearIcon, "lucide-settings"],
      [AppIcons.WindowExpandIcon, "lucide-maximize2"],
      [AppIcons.XIcon, "lucide-x"],
      [AppIcons.WarningIcon, "lucide-triangle-alert"],
      [AppIcons.WarningCircleIcon, "lucide-circle-alert"],
      [AppIcons.OpenExternalIcon, "lucide-external-link"],
      [AppIcons.ArrowSquareOutIcon, "lucide-external-link"],
      [AppIcons.SquareIcon, "lucide-square"],
    ];

    for (const [IconComponent, expectedClass] of cases) {
      expect(renderIcon(IconComponent)).toContain(expectedClass);
    }
  });
});
