import { resolveJavaTestClass } from "./java-test-launch-target";
import { describe, expect, mock, test } from "bun:test";
import type { JavaTestItems } from "@/platform/lsp-core-adapter";
import {
  discoverJavaTestMethods,
  javaTestMethodsFromItems,
} from "./java-test-discovery";

const discovered: JavaTestItems = {
  schemaVersion: 1,
  diagnostics: [],
  items: [
    {
      id: "class",
      label: "OddlyNamedSpec",
      fullName: "demo.OddlyNamedSpec",
      projectName: "app",
      testKind: 0,
      testLevel: 5,
      children: [
        {
          id: "second",
          label: "composed()",
          fullName: "demo.OddlyNamedSpec#composed()",
          projectName: "app",
          testKind: 0,
          testLevel: 6,
          range: {
            startLine: 12,
            startUtf16Column: 2,
            endLine: 14,
            endUtf16Column: 3,
          },
          children: [],
        },
        {
          id: "first",
          label: "parameterized(int)",
          fullName: "demo.OddlyNamedSpec#parameterized(int)",
          projectName: "app",
          testKind: 0,
          testLevel: 6,
          range: {
            startLine: 7,
            startUtf16Column: 2,
            endLine: 9,
            endUtf16Column: 3,
          },
          children: [],
        },
      ],
    },
  ],
};

describe("Java test discovery", () => {
  test("maps only JDT-confirmed method nodes in source order", () => {
    expect(javaTestMethodsFromItems(discovered.items)).toEqual([
      { name: "parameterized", line: 7, endLine: 9 },
      { name: "composed", line: 12, endLine: 14 },
    ]);
  });

  test("synchronizes the document before asking Core for typed JDT results", async () => {
    const calls: string[] = [];
    const ensureDocumentSynchronized = mock(async () => {
      calls.push("synchronize");
      return { phase: "ready" };
    });
    const invoke = mock(async (command: string, args: Record<string, unknown>) => {
      calls.push("discover");
      expect(command).toBe("java_test_items");
      expect(args).toEqual({ workspacePath: "C:/work", filePath: "C:/work/Odd.java" });
      return discovered;
    });

    await expect(
      discoverJavaTestMethods(
        { workspaceId: "workspace-1", root: "C:/work" },
        "C:/work/Odd.java",
        "class Odd {}",
        { ensureDocumentSynchronized },
        invoke,
      ),
    ).resolves.toEqual([
      { name: "parameterized", line: 7, endLine: 9 },
      { name: "composed", line: 12, endLine: 14 },
    ]);
    expect(calls).toEqual(["synchronize", "discover"]);
    expect(ensureDocumentSynchronized).toHaveBeenCalledWith(
      { filePath: "C:/work/Odd.java" },
      { workspaceId: "workspace-1", root: "C:/work" },
      "class Odd {}",
      "executeCommand",
    );
  });
});

describe("Java test launch ownership", () => {
  test("uses JDT's sibling and nested classes rather than the source filename", async () => {
    const sibling = { ...discovered.items[0]!, fullName: "demo.SecondTest", children: [
      { ...discovered.items[0]!, fullName: "demo.SecondTest$Nested", children: [] },
    ] };
    const invoke = mock(async () => ({ ...discovered, items: [discovered.items[0]!, sibling] }));
    for (const className of ["demo.SecondTest", "demo.SecondTest$Nested"]) {
      expect(await resolveJavaTestClass("C:/work", "C:/work/FirstTest.java", className, invoke))
        .toBe(className);
    }
    expect(invoke).toHaveBeenCalledWith("java_test_items", {
      workspacePath: "C:/work", filePath: "C:/work/FirstTest.java",
    });
    expect(await resolveJavaTestClass("C:/work", "C:/work/FirstTest.java", "demo.GoneTest", invoke)).toBeNull();
  });

  test("does not substitute a filename class when discovery fails", async () => {
    await expect(resolveJavaTestClass("C:/work", "C:/work/FirstTest.java", "demo.SecondTest", async () => {
      throw new Error("Java service unavailable");
    })).rejects.toThrow("Java service unavailable");
  });
});
