import { describe, expect, test } from "bun:test";
import { FILE_TREE_MIN_ROW_HEIGHT, getFileTreeRowHeight } from "./file-tree-row";

describe("file tree row geometry", () => {
  test("keeps the default UI font on the compact IDEA-style baseline", () => {
    expect(getFileTreeRowHeight(13)).toBe(FILE_TREE_MIN_ROW_HEIGHT);
  });

  test("allows larger accessibility font settings to grow the row", () => {
    expect(getFileTreeRowHeight(15)).toBe(26.25);
    expect(getFileTreeRowHeight(18)).toBe(30.3);
    expect(getFileTreeRowHeight(18.5)).toBe(30.98);
  });
});
