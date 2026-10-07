import { describe, expect, test } from "bun:test";
import {
  JAVA_TYPE_KINDS,
  isJavaIdentifier,
  isJavaPackageName,
  renderJavaType,
  suggestJavaSourceLocation,
} from "./java-source-template";

describe("Java source creation", () => {
  test("accepts Unicode names and rejects keywords, devices and traversal", () => {
    for (const name of ["App", "用户", "$Service", "_Type"])
      expect(isJavaIdentifier(name)).toBe(true);
    for (const name of [
      "",
      "class",
      "record",
      "CON",
      "nul",
      "../App",
      "A/B",
      "A.java",
      "1App",
      "A ",
      "A\n",
    ])
      expect(isJavaIdentifier(name)).toBe(false);
    expect(isJavaPackageName("com.example.示例")).toBe(true);
    for (const name of [".demo", "com..demo", "com.class", "com/evil", ""])
      expect(isJavaPackageName(name)).toBe(false);
  });
  test("renders each public type and only classes can request a main", () => {
    for (const kind of JAVA_TYPE_KINDS) {
      const text = renderJavaType(kind, "App", "demo", true);
      expect(text).toContain("package demo;");
      expect(text.includes("public static void main")).toBe(kind === "class");
    }
    expect(renderJavaType("annotation", "Flag", "")).toContain("public @interface Flag");
    expect(renderJavaType("record", "Point", "demo")).toContain("public record Point()");
    expect(renderJavaType("enum", "Mode", "")).toContain("public enum Mode");
    expect(() => renderJavaType("class", "../../Escape", "demo")).toThrow();
    expect(() => renderJavaType("packageInfo", "", "")).toThrow();
  });
  test("suggests source roots without duplicating package directories", () => {
    expect(
      suggestJavaSourceLocation("D:/work/app", "D:\\work\\app\\src\\main\\java\\com\\demo"),
    ).toEqual({ sourceRoot: "D:/work/app/src/main/java", packageName: "com.demo" });
    expect(suggestJavaSourceLocation("D:/work/app", "D:/work/app/src")).toEqual({
      sourceRoot: "D:/work/app/src",
      packageName: "",
    });
    expect(suggestJavaSourceLocation("D:/work/app", "D:/work/app/com/demo")).toEqual({
      sourceRoot: "D:/work/app",
      packageName: "com.demo",
    });
    expect(suggestJavaSourceLocation("D:/work/app", "D:/work/another")).toEqual({
      sourceRoot: "D:/work/another",
      packageName: "",
    });
  });
});

test("IDEA-style type list includes Exception without creating extra menu actions", () => {
  expect(renderJavaType("exception", "AppException", "demo")).toBe(
    "package demo;\n\npublic class AppException extends Exception {\n}\n",
  );
});
