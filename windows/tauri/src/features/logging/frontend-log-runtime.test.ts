import { describe, expect, test } from "bun:test";
import {
  sanitizeFrontendLogPayload,
  serializeConsoleArguments,
  setFrontendLogWorkspaceRoots,
} from "./frontend-log-runtime";

describe("frontend log serialization", () => {
  test("never throws for circular objects", () => {
    const value: Record<string, unknown> = { message: "failure" };
    value.self = value;
    expect(() => serializeConsoleArguments([value])).not.toThrow();
    expect(serializeConsoleArguments([value])).toContain("[circular]");
  });

  test("summarizes errors and limits stack frames", () => {
    const error = new Error("broken");
    error.stack = ["Error: broken", ...Array.from({ length: 20 }, (_, index) => `at frame${index}`)].join("\n");
    const serialized = serializeConsoleArguments([error]);
    expect(serialized).toContain("Error: broken");
    expect(serialized).toContain("frame7");
    expect(serialized).not.toContain("frame12");
  });

  test("truncates oversized payloads", () => {
    const serialized = serializeConsoleArguments(["x".repeat(5_000)]);
    expect(serialized.length).toBeLessThanOrEqual(3_000);
    expect(serialized).toContain("[truncated]");
  });

  test("relativizes registered workspace paths and shortens outside paths", () => {
    setFrontendLogWorkspaceRoots(["D:/work/project"]);
    expect(
      sanitizeFrontendLogPayload({
        filePath: "D:\\work\\project\\src\\main.ts",
        workspaceFolders: ["D:\\work\\project", "C:\\outside\\two"],
        root: "C:\\Users\\person\\outside.txt",
      }),
    ).toEqual({
      filePath: "<workspace>/src/main.ts",
      workspaceFolders: ["<workspace>", "two"],
      root: "outside.txt",
    });
  });
});
