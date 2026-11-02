import { expect, test } from "bun:test";
import { mergeRunActions } from "./merge-run-actions";
import type { RunActionItem } from "../types/run-action.types";

const workspace: RunActionItem = {
  id: "plugin:workspace",
  name: "Tests",
  source: "declarative",
  sourceLabel: "Plugin",
  declarativeOwner: { pluginId: "io.example.fixture", languageId: "java" },
  declarativeTest: true,
  declarativeTestScope: { kind: "workspace" },
  testTarget: { languageId: "java", frameworkId: "junit", scope: { kind: "workspace" } },
};
const fileScope = { kind: "file" as const, relativeFilePath: "src/Test.java" };
const file: RunActionItem = {
  ...workspace,
  id: "plugin:file",
  declarativeTestScope: fileScope,
  testTarget: { languageId: "java", frameworkId: "junit", scope: fileScope },
};

test("language tests win only their exact file scope and duplicate IDs have one owner", () => {
  const existing: RunActionItem = {
    id: "java:file",
    name: "Class",
    source: "maven",
    sourceLabel: "Maven",
    testTarget: { languageId: "java", frameworkId: "junit", scope: fileScope },
  };
  const merged = mergeRunActions([existing, existing], [], [workspace, file, workspace]);
  expect(merged.lspActions).toEqual([existing]);
  expect(merged.declarativeActions).toEqual([workspace]);
});

test("build workspace scopes take precedence while file scopes and opaque scripts stay separate", () => {
  const build: RunActionItem = {
    id: "build:test",
    name: "Tests",
    source: "cargo",
    sourceLabel: "Cargo",
    testTarget: { languageId: "java", frameworkId: "junit", scope: { kind: "workspace" } },
  };
  const opaque: RunActionItem = {
    id: "package:test",
    name: "Tests",
    source: "package",
    sourceLabel: "Scripts",
    command: "custom test",
  };
  const otherScope = { kind: "file" as const, relativeFilePath: "other/Test.java" };
  const other: RunActionItem = {
    ...file,
    id: "other:file",
    declarativeTestScope: otherScope,
    testTarget: { languageId: "java", frameworkId: "junit", scope: otherScope },
  };
  const merged = mergeRunActions([], [build, opaque], [workspace, file, other]);
  expect(merged.projectActions).toEqual([build, opaque]);
  expect(merged.declarativeActions).toEqual([file, other]);
});

test("the same language scope keeps distinct frameworks and unproven owners", () => {
  const otherFramework: RunActionItem = {
    ...workspace,
    id: "plugin:testng",
    declarativeOwner: { pluginId: "io.example.other", languageId: "java" },
    testTarget: { languageId: "java", frameworkId: "testng", scope: { kind: "workspace" } },
  };
  const unknownFramework: RunActionItem = {
    ...workspace,
    id: "plugin:unknown",
    declarativeOwner: { pluginId: "io.example.unknown", languageId: "java" },
    testTarget: undefined,
  };
  const unknownLanguageRunner: RunActionItem = {
    id: "java:workspace",
    name: "Tests",
    source: "lsp",
    sourceLabel: "Java",
    testTarget: { languageId: "java", scope: { kind: "workspace" } },
  };
  const merged = mergeRunActions(
    [unknownLanguageRunner],
    [],
    [workspace, otherFramework, unknownFramework],
  );
  expect(merged.lspActions).toEqual([unknownLanguageRunner]);
  expect(merged.declarativeActions).toEqual([workspace, otherFramework, unknownFramework]);
});
