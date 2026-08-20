import { describe, expect, test } from "bun:test";
import { countUniqueGitChanges, formatMemoryMegabytes } from "./footer-status";

describe("footer status helpers", () => {
  test("formats private working-set sizes in megabytes", () => {
    expect(formatMemoryMegabytes(213.7 * 1024 * 1024)).toBe("213.7 MB");
    expect(formatMemoryMegabytes(0)).toBe("0.0 MB");
  });

  test("counts unique Git paths", () => {
    expect(countUniqueGitChanges(undefined)).toBe(0);
    expect(
      countUniqueGitChanges([
        { path: "src/a.ts" },
        { path: "src/a.ts" },
        { path: "src/b.ts" },
      ]),
    ).toBe(2);
  });
});
