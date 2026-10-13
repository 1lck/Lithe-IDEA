import { describe, expect, test } from "bun:test";
import { isSameSpringRoot, isSupportedSpringRoot, normalizeSpringRootIdentity } from "./spring-root";

describe("isSupportedSpringRoot", () => {
  test("accepts local drive and UNC roots", () => {
    expect(isSupportedSpringRoot("C:\\work\\demo")).toBe(true);
    expect(isSupportedSpringRoot("C:/work/demo")).toBe(true);
    expect(isSupportedSpringRoot("\\\\server\\share\\demo")).toBe(true);
    expect(isSupportedSpringRoot("//server/share/demo")).toBe(true);
    expect(isSupportedSpringRoot("\\\\?\\C:\\work\\demo")).toBe(true);
  });

  test("rejects WSL, remote, and relative roots", () => {
    expect(isSupportedSpringRoot("wsl://Ubuntu/home/demo")).toBe(false);
    expect(isSupportedSpringRoot("remote://ssh-remote/demo")).toBe(false);
    expect(isSupportedSpringRoot("src/main/java")).toBe(false);
    expect(isSupportedSpringRoot(null)).toBe(false);
  });
});

describe("normalizeSpringRootIdentity", () => {
  test("normalizes separators, trailing separators, and drive case", () => {
    expect(normalizeSpringRootIdentity("C:\\work\\demo")).toBe("c:/work/demo");
    expect(normalizeSpringRootIdentity("C:/WORK/DEMO/")).toBe("c:/work/demo");
    expect(normalizeSpringRootIdentity("\\\\?\\C:\\Work\\Demo")).toBe("c:/work/demo");
  });

  test("preserves UNC path case while normalizing separators", () => {
    expect(normalizeSpringRootIdentity("\\\\Server\\Share\\Demo\\")).toBe(
      "//Server/Share/Demo",
    );
  });
});

describe("isSameSpringRoot", () => {
  test("treats textual variants of the same local root as the same root", () => {
    expect(isSameSpringRoot("C:\\work\\demo", "c:/work/demo/")).toBe(true);
    expect(isSameSpringRoot("\\\\?\\C:\\work\\demo", "C:/work/demo")).toBe(true);
  });

  test("rejects a different logical root", () => {
    expect(isSameSpringRoot("C:\\work\\demo", "D:\\work\\demo")).toBe(false);
    expect(isSameSpringRoot("wsl://Ubuntu/home/demo", "wsl://Ubuntu/home/demo")).toBe(false);
  });
});
