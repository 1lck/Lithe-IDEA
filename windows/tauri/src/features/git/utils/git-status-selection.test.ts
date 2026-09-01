import { describe, expect, test } from "bun:test";
import {
  buildGitIgnorePaths,
  collapseNestedGitStatusPaths,
  resolveGitFileMutationPaths,
  resolveGitStatusDeletionPaths,
  resolveGitStatusContextSelection,
  updateGitStatusSelection,
} from "./git-status-selection";

describe("Git status row selection", () => {
  test("includes both sides of a rename in Git mutations", () => {
    expect(
      resolveGitFileMutationPaths([
        {
          path: "src/new-name.ts",
          originalPath: "src/old-name.ts",
          status: "renamed",
          staged: true,
        },
        { path: "src/other.ts", status: "modified", staged: false },
      ]),
    ).toEqual(["src/new-name.ts", "src/old-name.ts", "src/other.ts"]);
  });

  test("keeps row selection independent from commit checkboxes", () => {
    const initial = new Set(["file:src/first.ts"]);

    expect(updateGitStatusSelection(initial, "file:src/second.ts", false)).toEqual(
      new Set(["file:src/second.ts"]),
    );
    expect(updateGitStatusSelection(initial, "file:src/second.ts", true)).toEqual(
      new Set(["file:src/first.ts", "file:src/second.ts"]),
    );
    expect(initial).toEqual(new Set(["file:src/first.ts"]));
  });

  test("right-click preserves an existing multi-selection", () => {
    const selected = new Set(["folder:tracked:src", "file:src/main.ts"]);

    expect(resolveGitStatusContextSelection(selected, "file:src/main.ts")).toEqual(selected);
    expect(resolveGitStatusContextSelection(selected, "file:other.ts")).toEqual(
      new Set(["file:other.ts"]),
    );
  });

  test("collapses nested paths", () => {
    expect(
      collapseNestedGitStatusPaths([
        "src/main.ts",
        "src",
        "tests/unit.ts",
        "tests\\integration.ts",
      ]),
    ).toEqual(["src", "tests/integration.ts", "tests/unit.ts"]);
  });

  test("keeps directory semantics while collapsing ignore targets", () => {
    expect(
      buildGitIgnorePaths([
        { kind: "file", path: "generated/output.txt" },
        { kind: "folder", path: "generated" },
        { kind: "file", path: "local.env" },
        { kind: "folder", path: "cache\\nested" },
      ]),
    ).toEqual(["cache/nested/", "generated/", "local.env"]);
  });

  test("deletes only source-control leaf files represented by selected folders", () => {
    expect(
      resolveGitStatusDeletionPaths([
        {
          files: [
            { path: "module/changed.ts", status: "modified" },
            { path: "module/new.ts", status: "untracked" },
            { path: "module/already-gone.ts", status: "deleted" },
          ],
        },
        {
          files: [{ path: "module/changed.ts", status: "modified" }],
        },
      ]),
    ).toEqual(["module/changed.ts", "module/new.ts"]);
  });
});
