import { describe, expect, mock, test } from "bun:test";
import type { MavenTestCase } from "@/features/maven/types/maven.types";
import {
  discoverJavaRunSources,
  javaRunMarkerForLine,
  projectJavaRunMarkers,
  type JavaRunMarker,
  type JavaRunSources,
} from "./java-run-markers";

const scope = { workspaceId: "workspace", root: "C:/work" };
const filePath = "C:/work/src/test/java/demo/OrderTest.java";

function marker(overrides: Partial<JavaRunMarker>): JavaRunMarker {
  return { line: 0, endLine: 0, kind: "main", label: "App.main()", status: "none", ...overrides };
}

describe("Java Run marker discovery", () => {
  test("synchronizes the document once and asks JDT for main methods and tests", async () => {
    const ensureDocumentSynchronized = mock(async () => undefined);
    const calls: Array<[string, Record<string, unknown>]> = [];
    const invoke = async <T,>(command: string, args: Record<string, unknown>): Promise<T> => {
      calls.push([command, args]);
      return (command === "java_main_methods"
        ? { schemaVersion: 1, methods: [], diagnostics: [] }
        : { schemaVersion: 1, items: [], diagnostics: [] }) as T;
    };

    await discoverJavaRunSources(scope, filePath, "class OrderTest {}", true, {
      ensureDocumentSynchronized,
    }, invoke);

    expect(ensureDocumentSynchronized).toHaveBeenCalledTimes(1);
    expect(calls.map(([command]) => command).sort()).toEqual([
      "java_main_methods",
      "java_test_items",
    ]);
    expect(calls[0]?.[1]).toEqual({ workspacePath: "C:/work", filePath });
  });

  test("does not ask for tests when the file cannot run them", async () => {
    const commands: string[] = [];
    const invoke = async <T,>(command: string): Promise<T> => {
      commands.push(command);
      return { schemaVersion: 1, methods: [], diagnostics: [] } as T;
    };

    const sources = await discoverJavaRunSources(scope, filePath, "", false, {
      ensureDocumentSynchronized: async () => undefined,
    }, invoke);

    expect(commands).toEqual(["java_main_methods"]);
    expect(sources.testItems).toEqual([]);
  });
});

describe("Java Run marker projection", () => {
  const sources: JavaRunSources = {
    mainMethods: [{
      mainClass: "demo.App",
      range: { startLine: 3, startUtf16Column: 23, endLine: 3, endUtf16Column: 27 },
    }],
    testItems: [],
  };

  test("sends JDT answers and recorded outcomes to Core's shared projection", async () => {
    const outcomes: MavenTestCase[] = [
      { className: "demo.OrderTest", method: "creates", status: "passed", invocations: 1 },
    ];
    const expected = [marker({ line: 3, endLine: 3, mainClass: "demo.App" })];
    const executor = mock(async (request: { command: string; payload: unknown }) => {
      expect(request.command).toBe("java.runMarkers");
      expect(request.payload).toEqual({
        mainMethods: sources.mainMethods,
        testItems: [],
        testCases: outcomes,
      });
      return { ok: true as const, data: { markers: expected } };
    });

    expect(await projectJavaRunMarkers(sources, outcomes, executor as never)).toEqual(expected);
    expect(executor).toHaveBeenCalledTimes(1);
  });

  test("skips Core when JDT found nothing to run", async () => {
    const executor = mock(async () => ({ ok: true as const, data: { markers: [] } }));

    expect(await projectJavaRunMarkers({ mainMethods: [], testItems: [] }, [], executor as never))
      .toEqual([]);
    expect(executor).not.toHaveBeenCalled();
  });

  test("surfaces a Core failure instead of reporting no markers", async () => {
    const executor = async () => ({
      ok: false as const,
      error: { code: "invalid_request", message: "Too many Run markers for one file" },
    });

    await expect(projectJavaRunMarkers(sources, [], executor as never)).rejects.toThrow(
      "Too many Run markers",
    );
  });
});

describe("Run marker under the caret", () => {
  const markers: JavaRunMarker[] = [
    marker({ line: 2, endLine: 2, kind: "main", label: "App.main()", mainClass: "demo.App" }),
    marker({ line: 5, endLine: 14, kind: "testClass", label: "OrderTest" }),
    marker({ line: 7, endLine: 7, kind: "testMethod", label: "OrderTest.creates" }),
    marker({ line: 10, endLine: 13, kind: "testClass", label: "Refunds" }),
    marker({ line: 12, endLine: 12, kind: "testMethod", label: "Refunds.refunds" }),
  ];

  test("prefers the innermost test declaration that contains the caret", () => {
    expect(javaRunMarkerForLine(markers, 7)?.label).toBe("OrderTest.creates");
    expect(javaRunMarkerForLine(markers, 12)?.label).toBe("Refunds.refunds");
    expect(javaRunMarkerForLine(markers, 11)?.label).toBe("Refunds");
    expect(javaRunMarkerForLine(markers, 8)?.label).toBe("OrderTest");
    expect(javaRunMarkerForLine(markers, 14)?.label).toBe("OrderTest");
  });

  test("falls back to the file's main method outside any test declaration", () => {
    expect(javaRunMarkerForLine(markers, 0)?.label).toBe("App.main()");
    expect(javaRunMarkerForLine(markers, 20)?.label).toBe("App.main()");
  });

  test("uses the main on the caret line when a file declares several", () => {
    const mains = [
      marker({ line: 3, endLine: 3, label: "App.main()" }),
      marker({ line: 6, endLine: 6, label: "Inner.main()" }),
    ];
    expect(javaRunMarkerForLine(mains, 6)?.label).toBe("Inner.main()");
    expect(javaRunMarkerForLine(mains, 9)?.label).toBe("App.main()");
    expect(javaRunMarkerForLine([], 1)).toBeNull();
  });
});
