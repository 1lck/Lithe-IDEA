import { expect, test } from "bun:test";
import {
  collapseSelectedTreePaths,
  selectTreeEntries,
  selectVisibleTreeSiblings,
} from "./tree-selection";

test("Shift extends and shrinks a range from the original visible anchor", () => {
  const order = ["folder", "a", "b", "c"];
  const first = selectTreeEntries(new Set(), "a", order, null);
  const expanded = selectTreeEntries(first.selected, "c", order, first.anchor, { range: true });
  expect([...expanded.selected]).toEqual(["a", "b", "c"]);
  const shrunk = selectTreeEntries(expanded.selected, "b", order, expanded.anchor, { range: true });
  expect([...shrunk.selected]).toEqual(["a", "b"]);
  expect(shrunk.anchor).toBe("a");
});

test("Ctrl toggles and Ctrl Shift unions a visible range; removed anchor starts a new selection", () => {
  expect([
    ...selectTreeEntries(new Set(["a", "b"]), "a", ["a", "b"], "b", { additive: true }).selected,
  ]).toEqual(["b"]);
  expect([
    ...selectTreeEntries(new Set(["x"]), "c", ["a", "b", "c"], "a", { additive: true, range: true })
      .selected,
  ]).toEqual(["x", "a", "b", "c"]);
  expect([
    ...selectTreeEntries(new Set(["hidden"]), "b", ["a", "b"], "hidden", { range: true }).selected,
  ]).toEqual(["b"]);
});

test("batch operations collapse nested and duplicate Windows paths once", () => {
  expect(
    collapseSelectedTreePaths([
      { path: "C:/workspace/src/a.ts" },
      { path: "c:\\WORKSPACE\\src" },
      { path: "C:/workspace/src/" },
      { path: "C:/workspace/src-other/b.ts" },
    ]).map((entry) => entry.path),
  ).toEqual(["c:\\WORKSPACE\\src", "C:/workspace/src-other/b.ts"]);
});

test("Ctrl A selects displayed siblings without ancestors, descendants, or cousins", () => {
  const rows = [
    [0, "project"],
    [1, "project/src"],
    [2, "project/src/com/example"],
    [3, "project/src/com/example/A.java"],
    [2, "project/src/org/demo"],
    [1, "project/test"],
    [2, "project/test/com/example"],
    [0, "other-project"],
  ].map(([depth, path]) => ({ depth: depth as number, file: { path: path as string } }));
  expect([...selectVisibleTreeSiblings(rows, 2)]).toEqual([
    "project/src/com/example",
    "project/src/org/demo",
  ]);
  expect([...selectVisibleTreeSiblings(rows, 1)]).toEqual(["project/src", "project/test"]);
  expect([...selectVisibleTreeSiblings(rows, 0)]).toEqual(["project", "other-project"]);
  expect([...selectVisibleTreeSiblings(rows, -1)]).toEqual([]);
});

test("case-sensitive WSL, remote and POSIX selections retain distinct files and subtrees", () => {
  for (const root of [
    "wsl://Ubuntu/project",
    "remote://fixture/project",
    "/project",
    "//wsl.localhost/Ubuntu/project",
    "//wsl$/Ubuntu/project",
    "//?/UNC/wsl.localhost/Ubuntu/project",
  ]) {
    const entries = ["src/a.ts", "src/A.ts", "Src", "src/nested", "src/nested/b.ts"].map(
      (path) => ({ path: `${root}/${path}` }),
    );
    expect(collapseSelectedTreePaths(entries)).toEqual(entries.slice(0, 4));
  }
});

test("native Windows UNC and verbatim paths collapse case aliases", () => {
  const entries = [
    { path: "//server/share/src/a.ts" },
    { path: "\\\\?\\UNC\\SERVER\\SHARE\\SRC" },
    { path: "//server/share/src/" },
    { path: "C:/project/a.ts" },
    { path: "\\\\?\\c:\\PROJECT\\A.ts" },
  ];
  expect(collapseSelectedTreePaths(entries)).toEqual([entries[1], entries[3]]);
});
