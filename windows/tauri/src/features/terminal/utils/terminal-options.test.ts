import { describe, expect, test } from "bun:test";
import { getTerminalCompatibilityOptions } from "./terminal-options";

describe("terminal compatibility options", () => {
  test("uses VS Code-compatible ED2 scrolling for every terminal", () => {
    expect(getTerminalCompatibilityOptions({ platform: "windows", isRemote: true })).toMatchObject({
      scrollOnEraseInDisplay: true,
    });
    expect(getTerminalCompatibilityOptions({ platform: "linux", isRemote: true })).toMatchObject({
      scrollOnEraseInDisplay: true,
    });
  });
});
