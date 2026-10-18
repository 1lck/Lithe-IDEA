import { describe, expect, test } from "bun:test";
import { windowsPathToWslPath } from "./wsl-path";

describe("windowsPathToWslPath", () => {
  test("maps a drive path under /mnt using a lowercase drive letter", () => {
    expect(windowsPathToWslPath("C:\\work\\proj\\a.txt")).toBe("/mnt/c/work/proj/a.txt");
    expect(windowsPathToWslPath("D:\\data\\b.bin")).toBe("/mnt/d/data/b.bin");
  });

  test("accepts forward slashes in a drive path", () => {
    expect(windowsPathToWslPath("C:/work/a.txt")).toBe("/mnt/c/work/a.txt");
  });

  test("maps a drive root", () => {
    expect(windowsPathToWslPath("C:\\")).toBe("/mnt/c");
  });

  test("keeps a path that is already in Linux form", () => {
    expect(windowsPathToWslPath("/home/me/a.txt")).toBe("/home/me/a.txt");
  });

  // A UNC share has no predictable mount point inside the distribution, so the
  // caller must keep the original rather than insert a path that points nowhere.
  test("reports an untranslatable UNC path", () => {
    expect(windowsPathToWslPath("\\\\server\\share\\a.txt")).toBeNull();
  });

  test("reports an untranslatable relative path", () => {
    expect(windowsPathToWslPath("src/Main.java")).toBeNull();
  });
});
