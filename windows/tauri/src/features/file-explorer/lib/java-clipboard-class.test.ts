import { describe, expect, test } from "bun:test";
import {
  javaTypeFileName,
  parseJavaTypeClipboard,
} from "./java-clipboard-class";

describe("parseJavaTypeClipboard", () => {
  test("parses a public class with package and annotations", () => {
    const text = `package com.yupi.usercenter.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class MappingPrefixDemoController {
  @GetMapping("/real")
  public String real() { return "real"; }
}
`;
    const parsed = parseJavaTypeClipboard(text);
    expect(parsed?.typeName).toBe("MappingPrefixDemoController");
    expect(parsed?.content).toContain("@GetMapping(\"/real\")");
  });

  test("prefers the public type when a package-private decoy exists first", () => {
    const text = `class Helper {}
public interface TeamApi {}
`;
    expect(parseJavaTypeClipboard(text)?.typeName).toBe("TeamApi");
  });

  test("falls back to the first top-level type without public", () => {
    const text = `package demo;\nenum Status { OK }\n`;
    expect(parseJavaTypeClipboard(text)?.typeName).toBe("Status");
  });

  test("parses records and rejects non-type clipboard text", () => {
    expect(parseJavaTypeClipboard("public record Point(int x, int y) {}")?.typeName).toBe(
      "Point",
    );
    expect(parseJavaTypeClipboard("just some notes")).toBeNull();
    expect(parseJavaTypeClipboard("")).toBeNull();
  });

  test("ignores nested types at brace depth greater than zero", () => {
    const text = `class Outer {
  public static class Inner {}
}
`;
    expect(parseJavaTypeClipboard(text)?.typeName).toBe("Outer");
  });

  test("ignores type declarations inside comments", () => {
    const text = `/* public class FakeInBlock {} */
// public class FakeInLine {}
public class Real {}
`;
    expect(parseJavaTypeClipboard(text)?.typeName).toBe("Real");
  });
});

describe("javaTypeFileName", () => {
  test("uses the type name as the java file name", () => {
    expect(javaTypeFileName("MappingPrefixDemoController")).toBe(
      "MappingPrefixDemoController.java",
    );
  });
});
