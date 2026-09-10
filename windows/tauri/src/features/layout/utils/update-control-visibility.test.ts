import { describe, expect, test } from "bun:test";
import { getUpdateControlVisibility } from "./update-control-visibility";

describe("update control visibility", () => {
  test("keeps the update entry on exactly one layout surface", () => {
    expect(getUpdateControlVisibility(undefined)).toEqual({
      showTitleBarControl: false,
      showWelcomeControl: true,
    });
    expect(getUpdateControlVisibility("C:/workspaces/lithe")).toEqual({
      showTitleBarControl: true,
      showWelcomeControl: false,
    });
  });
});
