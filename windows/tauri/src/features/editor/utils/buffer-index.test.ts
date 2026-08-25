import { describe, expect, test } from "bun:test";
import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { areBufferPathsEqual, getBufferByPath } from "./buffer-index";

describe("buffer path index", () => {
  test("matches Windows paths across separators, drive case, and file URI leading slash", () => {
    const buffer = {
      id: "editor-buffer",
      path: "C:\\Work\\src\\Main.java",
    } as PaneContent;

    expect(getBufferByPath([buffer], "c:/Work/src/Main.java")).toBe(buffer);
    expect(getBufferByPath([buffer], "/C:/Work/src/Main.java")).toBe(buffer);
    expect(areBufferPathsEqual(buffer.path, "c:/Work/src/Main.java")).toBe(true);
  });

  test("keeps non-Windows buffer identities case-sensitive", () => {
    const buffer = {
      id: "virtual-buffer",
      path: "jdt://contents/demo/String.class?A",
    } as PaneContent;

    expect(
      getBufferByPath([buffer], "jdt://contents/demo/String.class?A"),
    ).toBe(buffer);
    expect(
      getBufferByPath([buffer], "jdt://contents/demo/String.class?a"),
    ).toBeNull();
    expect(
      areBufferPathsEqual(
        "jdt://contents/demo/String.class?A",
        "jdt://contents/demo/String.class?a",
      ),
    ).toBe(false);
  });
});
