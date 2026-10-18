import { describe, expect, test } from "bun:test";
import { pathToWslPath, windowsPathToWslPath } from "./wsl-path";

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

describe("pathToWslPath", () => {
  // Regression: the explorer's WSL root uses the `wsl://<distro>/<path>` protocol
  // form, which the plain Windows translator reports as untranslatable. The
  // original value was then inserted and Linux could not reach the directory.
  test("extracts the Linux path from a workspace protocol path", () => {
    expect(pathToWslPath("wsl://Ubuntu/home/me/proj", "Ubuntu")).toBe("/home/me/proj");
  });

  test("matches the distribution case-insensitively", () => {
    expect(pathToWslPath("wsl://ubuntu/home/me/proj", "Ubuntu")).toBe("/home/me/proj");
  });

  // A path in another distribution is not reachable from this one, so the caller
  // must keep the original rather than insert a guess.
  test("reports a path from a different distribution", () => {
    expect(pathToWslPath("wsl://Debian/home/me/proj", "Ubuntu")).toBeNull();
  });

  test("translates a local Windows drive inside a WSL session", () => {
    expect(pathToWslPath("C:\\work\\a.txt", "Ubuntu")).toBe("/mnt/c/work/a.txt");
  });

  test("keeps an already Linux path", () => {
    expect(pathToWslPath("/home/me/a.txt", "Ubuntu")).toBe("/home/me/a.txt");
  });

  test("reports an untranslatable UNC path", () => {
    expect(pathToWslPath("\\\\server\\share\\a.txt", "Ubuntu")).toBeNull();
  });
});
