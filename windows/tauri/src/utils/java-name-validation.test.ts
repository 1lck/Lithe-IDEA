import { expect, test } from "bun:test";
import { isJavaIdentifier, isJavaPackageName } from "./java-name-validation";

test("creation identifiers retain Unicode letters, marks and Java identifier symbols", () => {
  for (const name of ["App", "_App", "$App", "示例", "a\u0301", "€Value"]) {
    expect(isJavaIdentifier(name)).toBe(true);
  }
});

test("creation identifiers reject keywords, path syntax and Windows device names", () => {
  for (const name of [
    "",
    "class",
    "9App",
    "bad-name",
    "CON",
    "Nul",
    "COM1",
    "Lpt9",
    "a/b",
    "a\\b",
    "x".repeat(151),
  ]) {
    expect(isJavaIdentifier(name)).toBe(false);
  }
});

test("package names validate each bounded segment and only explicitly allow the default package", () => {
  expect(isJavaPackageName("com.example")).toBe(true);
  expect(isJavaPackageName("示例.工具")).toBe(true);
  expect(isJavaPackageName("", true)).toBe(true);
  for (const name of [
    "",
    "com..app",
    ".app",
    "app.",
    "com.class",
    "../outside",
    "ab.".repeat(80) + "x",
  ]) {
    expect(isJavaPackageName(name)).toBe(false);
  }
});
