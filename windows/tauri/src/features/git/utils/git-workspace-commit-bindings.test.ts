import { expect, test } from "bun:test";
import { workspaceCommitBindings } from "./git-workspace-commit-bindings";

test("binds nested, enclosing and same-volume sibling repositories without absolute IDs", () => {
  expect(
    workspaceCommitBindings("C:\\work\\project", [
      "c:/work/project",
      "C:/work/project/libs/B",
      "C:/work",
      "C:/other",
    ]).map((binding) => binding.id),
  ).toEqual([".", "libs/B", "..", "../../other"]);
});
test("normalizes verbatim roots and gives another volume a stable virtual ID", () => {
  expect(
    workspaceCommitBindings("C:/work", ["\\\\?\\C:\\work\\B", "D:/repo"]).map(
      (binding) => binding.id,
    ),
  ).toEqual(["B", "external/D%3A/repo"]);
});
