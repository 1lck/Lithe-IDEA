import { beforeAll, describe, expect, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/workspace/visibility-v1.json";
import * as coreRules from "@/core/core-rules";
import { executeCoreRuleSync } from "@/core/core-rules";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import { filterFileTreeEntries } from "./visible-file-tree-rows";
import {
  classifyRelativePaths,
  createDirectoryVisibilityClassifier,
} from "./file-tree-visibility";
import type { FileEntry } from "@/features/file-system/types/app.types";

// The same fixture drives the Rust tests in lithe-core-rules and lithe-core and the macOS
// FileVisibilityRules tests, so every host hides the same paths. Here it runs through real wasm.
beforeAll(loadCoreRulesForTests);

describe("hidden-path classification (shared fixture through wasm)", () => {
  test("the built-in lists come from Core", () => {
    expect(executeCoreRuleSync("workspace.visibilityDefaults", {})).toEqual(fixture.defaults);
  });

  for (const testCase of fixture.cases) {
    test(testCase.name, () => {
      const hidden = classifyRelativePaths(
        {
          hiddenDirectoryNames: testCase.hiddenDirectoryNames,
          hiddenFilePatterns: testCase.hiddenFilePatterns,
        },
        testCase.entries.map((entry) => ({ path: entry.path, isDirectory: entry.isDirectory })),
      );
      expect(hidden).toEqual(testCase.entries.map((entry) => entry.hidden));
    });
  }
});

describe("directory classifier", () => {
  const root = "C:/work/project";
  const rules = { hiddenDirectoryNames: [], hiddenFilePatterns: ["*.log"] };
  const rootFor = (path: string) => (path.startsWith(root) ? root : null);
  const children = [
    { path: `${root}/node_modules`, isDir: true },
    { path: `${root}/src`, isDir: true },
    { path: `${root}/debug.log`, isDir: false },
    { path: `${root}/README.md`, isDir: false },
  ];

  test("classifies every child of a directory with one Core call and caches the answer", () => {
    const spy = spyOn(coreRules, "executeCoreRuleSync");
    try {
      const classifier = createDirectoryVisibilityClassifier(rules, rootFor);
      expect(classifier.classifyChildren(root, children)).toEqual([true, false, true, false]);
      expect(spy).toHaveBeenCalledTimes(1);
      expect(classifier.classifyChildren(root, children)).toEqual([true, false, true, false]);
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      spy.mockRestore();
    }
  });

  test("a new rule set starts with an empty cache", () => {
    const spy = spyOn(coreRules, "executeCoreRuleSync");
    try {
      createDirectoryVisibilityClassifier(rules, rootFor).classifyChildren(root, children);
      createDirectoryVisibilityClassifier({ ...rules, hiddenFilePatterns: [] }, rootFor).classifyChildren(
        root,
        children,
      );
      expect(spy).toHaveBeenCalledTimes(2);
    } finally {
      spy.mockRestore();
    }
  });

  test("workspace roots and paths outside every root are never hidden", () => {
    const classifier = createDirectoryVisibilityClassifier(rules, rootFor);
    expect(
      classifier.classifyChildren("", [
        { path: root, isDir: true },
        { path: "D:/elsewhere/node_modules", isDir: true },
      ]),
    ).toEqual([false, false]);
  });

  test("filtering a tree asks Core once per directory, not once per file", () => {
    const file = (name: string, parent: string): FileEntry => ({ name, path: `${parent}/${name}`, isDir: false });
    const src: FileEntry = {
      name: "src",
      path: `${root}/src`,
      isDir: true,
      children: [file("a.ts", `${root}/src`), file("b.log", `${root}/src`), file("c.ts", `${root}/src`)],
    };
    const tree: FileEntry[] = [
      {
        name: "project",
        path: root,
        isDir: true,
        children: [src, file("debug.log", root), { name: "target", path: `${root}/target`, isDir: true, children: [] }],
      },
    ];
    const spy = spyOn(coreRules, "executeCoreRuleSync");
    try {
      const classifier = createDirectoryVisibilityClassifier(rules, rootFor);
      const result = filterFileTreeEntries(tree, {
        isAlwaysHidden: () => false,
        isGitIgnored: () => false,
        isHiddenName: () => false,
        classifyUserHidden: classifier.classifyChildren,
        showGitignoredFiles: true,
        showHiddenFiles: true,
      });
      const names = (entries: FileEntry[] | undefined): string[] =>
        (entries ?? []).flatMap((entry) => [entry.name, ...names(entry.children)]);
      expect(names(result)).toEqual(["project", "src", "a.ts", "c.ts"]);
      // The workspace root level has one entry; project and src each get one call.
      expect(spy.mock.calls.length).toBeLessThanOrEqual(2);
    } finally {
      spy.mockRestore();
    }
  });
});
