import { describe, expect, test } from "bun:test";
import {
  RUN_CONFIGURATION_LIST_DEFAULT_WIDTH,
  RUN_CONFIGURATION_LIST_MAX_WIDTH,
  RUN_CONFIGURATION_LIST_MIN_WIDTH,
  clampRunConfigurationListWidth,
  getRunConfigurationListMaxWidth,
} from "./run-configuration-list-layout";

describe("run configuration list layout", () => {
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
    expect(clampRunConfigurationListWidth(Number.NaN, 900)).toBe(RUN_CONFIGURATION_LIST_DEFAULT_WIDTH);
  });
});
