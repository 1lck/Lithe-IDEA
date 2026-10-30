import { expect, test } from "bun:test";
import { javaImportOnOpenDecision } from "./java-import-on-open";

test("opening a project follows the import policy", () => {
  expect(javaImportOnOpenDecision("automatic", false)).toBe("start");
  expect(javaImportOnOpenDecision("ask", false)).toBe("ask");
  expect(javaImportOnOpenDecision("manual", false)).toBe("skip");
});

test("reactivating a project whose import already runs never asks or stops it", () => {
  for (const policy of ["automatic", "ask", "manual"] as const) {
    expect(javaImportOnOpenDecision(policy, true)).toBe("start");
  }
});
