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
    const ensureDocumentReady = mock(async () => ({ phase: "ready" }));
    const invoke = mock(async (command: string, args: Record<string, unknown>) => {
      expect(command).toBe("java_test_items");
      expect(args).toEqual({ workspacePath: "C:/work", filePath: "C:/work/Odd.java" });
      return discovered;
    });

    await expect(
      discoverJavaTestMethods(
        { workspaceId: "workspace-1", root: "C:/work" },
        "C:/work/Odd.java",
        "class Odd {}",
        { ensureDocumentReady },
        invoke,
      ),
    ).resolves.toEqual([
      { name: "parameterized", line: 7, endLine: 9 },
      { name: "composed", line: 12, endLine: 14 },
    ]);
    expect(ensureDocumentReady).toHaveBeenCalledWith(
      { filePath: "C:/work/Odd.java" },
      { workspaceId: "workspace-1", root: "C:/work" },
      "class Odd {}",
      "executeCommand",
    );
  });
});
