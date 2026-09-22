import { executeCore, type CoreRequest, type CoreResponse } from "@/core/lithe-core-client";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import type { MavenTestCase } from "@/features/maven/types/maven.types";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import {
  invokeLsp,
  type JavaMainMethod,
  type JavaMainMethods,
  type JavaTestItem,
  type JavaTestItems,
} from "@/platform/lsp-core-adapter";

// Note: 设计见 .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md

export type JavaRunMarkerKind = "main" | "testClass" | "testMethod";
export type JavaRunMarkerStatus = "none" | "passed" | "failed" | "skipped";

/** One IDEA-style gutter marker projected by Core's `java.runMarkers`. */
export interface JavaRunMarker {
  /** Zero-based line of the declaration name. */
  line: number;
  /** Last line of the declaration: body end for tests, name line for `main`. */
  endLine: number;
  kind: JavaRunMarkerKind;
  /** Menu target such as `App.main()`, `OrderTest`, or `OrderTest.creates`. */
  label: string;
  mainClass?: string;
  projectName?: string;
  testClass?: string;
  testMethod?: string;
  testItemId?: string;
  status: JavaRunMarkerStatus;
}

/** JDT answers for one file; the inputs of a marker projection. */
export interface JavaRunSources {
  mainMethods: JavaMainMethod[];
  testItems: JavaTestItem[];
}

interface JavaRunSourceClient {
  ensureDocumentSynchronized(
    target: { filePath: string },
    scope: WorkspaceLaunchScope,
    content: string,
    feature?: string,
  ): Promise<unknown>;
}

type JavaRunSourceInvoker = <T>(command: string, args: Record<string, unknown>) => Promise<T>;

/**
 * Synchronizes the editor document once, then asks JDT which `main` methods
 * it can launch and, when tests can run for this file, which declarations are
 * tests. Neither answer is derived from source text locally.
 */
export async function discoverJavaRunSources(
  scope: WorkspaceLaunchScope,
  filePath: string,
  content: string,
  includeTests: boolean,
  client: JavaRunSourceClient = LspClient.getInstance(),
  invokeCommand: JavaRunSourceInvoker = (command, args) => invokeLsp(command, args),
): Promise<JavaRunSources> {
  await client.ensureDocumentSynchronized({ filePath }, scope, content, "executeCommand");
  const args = { workspacePath: scope.root, filePath };
  const [mainMethods, testItems] = await Promise.all([
    invokeCommand<JavaMainMethods>("java_main_methods", args),
    includeTests
      ? invokeCommand<JavaTestItems>("java_test_items", args)
      : Promise.resolve<JavaTestItems>({ schemaVersion: 1, items: [], diagnostics: [] }),
  ]);
  return { mainMethods: mainMethods.methods, testItems: testItems.items };
}

type JavaRunMarkerExecutor = (
  request: CoreRequest<{
    mainMethods: JavaMainMethod[];
    testItems: JavaTestItem[];
    testCases: MavenTestCase[];
  }>,
) => Promise<CoreResponse<{ markers: JavaRunMarker[] }>>;

/** Combines JDT answers and recorded outcomes through Core's shared projection. */
export async function projectJavaRunMarkers(
  sources: JavaRunSources,
  testCases: readonly MavenTestCase[],
  executor: JavaRunMarkerExecutor = executeCore,
): Promise<JavaRunMarker[]> {
  if (sources.mainMethods.length === 0 && sources.testItems.length === 0) return [];
  const operationId = crypto.randomUUID();
  const response = await executor({
    id: operationId,
    operationId,
    command: "java.runMarkers",
    payload: {
      mainMethods: sources.mainMethods,
      testItems: sources.testItems,
      testCases: [...testCases],
    },
  });
  if (response.ok) return response.data.markers;
  throw new Error(response.error.message);
}

/**
 * Picks the marker a caret line refers to for context-menu and keyboard runs,
 * following IDEA: the innermost test method or class whose declaration
 * contains the line, otherwise the `main` on that line, otherwise the file's
 * first `main`. JDT reports only the name of a `main` method, not its class
 * body, so a file's first `main` stands for the file.
 */
export function javaRunMarkerForLine(
  markers: readonly JavaRunMarker[],
  line: number,
): JavaRunMarker | null {
  let enclosingTest: JavaRunMarker | null = null;
  for (const marker of markers) {
    if (marker.kind === "main" || line < marker.line || line > marker.endLine) continue;
    if (
      !enclosingTest ||
      marker.line > enclosingTest.line ||
      (marker.line === enclosingTest.line && marker.kind === "testMethod")
    ) {
      enclosingTest = marker;
    }
  }
  if (enclosingTest) return enclosingTest;
  const mains = markers.filter((marker) => marker.kind === "main");
  return mains.find((marker) => marker.line === line) ?? mains[0] ?? null;
}
