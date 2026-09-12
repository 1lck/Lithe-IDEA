import { describe, expect, test } from "bun:test";
import { getVisibleGitReferenceToolbarActionCount } from "./git-reference-toolbar-layout";

describe("Git reference toolbar overflow", () => {
  test("shows every action only when the full toolbar and separator fit", () => {
    expect(getVisibleGitReferenceToolbarActionCount(337, 10)).toBe(10);
    expect(getVisibleGitReferenceToolbarActionCount(336, 10)).toBe(9);
  });

  test("reserves the final available slot for the overflow trigger", () => {
    expect(getVisibleGitReferenceToolbarActionCount(136, 10)).toBe(3);
    expect(getVisibleGitReferenceToolbarActionCount(72, 10)).toBe(1);
  });

  test("moves every action into overflow when the toolbar is extremely short", () => {
    expect(getVisibleGitReferenceToolbarActionCount(39, 10)).toBe(0);
    expect(getVisibleGitReferenceToolbarActionCount(200, 0)).toBe(0);
  });
});
