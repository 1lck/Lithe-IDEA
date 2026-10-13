import { describe, expect, test } from "bun:test";
import {
  RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
  RUN_CONFIGURATION_LIST_MAX_WIDTH,
  RUN_CONFIGURATION_LIST_MIN_WIDTH,
  clampRunConfigurationListWidth,
  getRunConfigurationListMaxWidth,
  getRunLanguageColumnWidth,
  RUN_LANGUAGE_COLUMN_WIDTH,
  RUN_LANGUAGE_COLUMN_COMPACT_WIDTH,
  RUN_LANGUAGE_COLUMN_MIN_WIDTH,
  RUN_LANGUAGE_COLUMN_MAX_WIDTH,
  RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
  runLanguageColumnDragWidth,
} from "./run-configuration-list-layout";

describe("run configuration list layout", () => {
  test("language rail collapses before consuming configuration and output minimums", () => {
    expect(getRunLanguageColumnWidth(900)).toBe(RUN_LANGUAGE_COLUMN_WIDTH);
    expect(getRunLanguageColumnWidth(620)).toBe(RUN_LANGUAGE_COLUMN_MIN_WIDTH);
    expect(getRunLanguageColumnWidth(619)).toBe(RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
    expect(
      clampRunConfigurationListWidth(
        420,
        700 - getRunLanguageColumnWidth(700) - RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
      ),
    ).toBe(228);
    expect(
      clampRunConfigurationListWidth(
        420,
        600 - getRunLanguageColumnWidth(600) - RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
      ),
    ).toBe(240);
  });
  test("drag snapping uses separate collapse and expansion thresholds within available space", () => {
    expect(runLanguageColumnDragWidth(79, 900, false)).toBe(RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
    expect(runLanguageColumnDragWidth(80, 900, false)).toBe(RUN_LANGUAGE_COLUMN_MIN_WIDTH);
    expect(runLanguageColumnDragWidth(95, 900, true)).toBe(RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
    expect(runLanguageColumnDragWidth(96, 900, true)).toBe(RUN_LANGUAGE_COLUMN_MIN_WIDTH);
    expect(runLanguageColumnDragWidth(160, 900, true)).toBe(160);
    expect(runLanguageColumnDragWidth(240, 700, false)).toBe(192);
    expect(runLanguageColumnDragWidth(240, 600, false)).toBe(RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
  });
  test("language width honors manual collapse, finite limits and space reserved for output", () => {
    expect(getRunLanguageColumnWidth(900, 200)).toBe(200);
    expect(getRunLanguageColumnWidth(900, 200, true)).toBe(RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
    expect(getRunLanguageColumnWidth(900, Number.NaN)).toBe(RUN_LANGUAGE_COLUMN_WIDTH);
    expect(getRunLanguageColumnWidth(900, 30)).toBe(RUN_LANGUAGE_COLUMN_MIN_WIDTH);
    expect(getRunLanguageColumnWidth(900, 900)).toBe(RUN_LANGUAGE_COLUMN_MAX_WIDTH);
    expect(getRunLanguageColumnWidth(700, 240)).toBe(192);
  });
  test("keeps the macOS default within the normal bottom-pane width", () => {
    expect(clampRunConfigurationListWidth(RUN_CONFIGURATION_LIST_DEFAULT_WIDTH, 900)).toBe(
      RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
    );
  });

  test("clamps below the minimum and above the absolute maximum", () => {
    expect(clampRunConfigurationListWidth(80, 900)).toBe(RUN_CONFIGURATION_LIST_MIN_WIDTH);
    expect(clampRunConfigurationListWidth(800, 900)).toBe(RUN_CONFIGURATION_LIST_MAX_WIDTH);
  });

  test("keeps at least the list minimum when the container is narrow", () => {
    // Matches macOS: max(minimumListWidth, available) so a narrow pane still shows the list.
    expect(getRunConfigurationListMaxWidth(400)).toBe(RUN_CONFIGURATION_LIST_MIN_WIDTH);
    expect(clampRunConfigurationListWidth(230, 400)).toBe(RUN_CONFIGURATION_LIST_MIN_WIDTH);
  });

  test("falls back to a safe width for non-finite values", () => {
    expect(clampRunConfigurationListWidth(Number.NaN, 900)).toBe(
      RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
    );
  });
});
