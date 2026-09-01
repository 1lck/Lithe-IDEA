import { describe, expect, test } from "bun:test";
import type { GitFile } from "../types/git.types";
import { buildVisibleGitFiles } from "./git-status-model";

const files: GitFile[] = [
  { path: "src/tracked.ts", status: "modified", staged: false },
  { path: "src/new.ts", status: "untracked", staged: false },
];

describe("Git status model", () => {
  test("keeps hidden untracked files out of both rendering and commit lookup", () => {
    const presentation = buildVisibleGitFiles(files, false);

    expect(presentation.files).toEqual([files[0]]);
    expect([...presentation.fileByPath.keys()]).toEqual(["src/tracked.ts"]);
    expect(presentation.fileByPath.has("src/new.ts")).toBe(false);
  });

  test("includes untracked files when the setting is enabled", () => {
    const presentation = buildVisibleGitFiles(files, true);
    expect(presentation.files).toEqual(files);
    expect([...presentation.fileByPath.keys()]).toEqual(["src/tracked.ts", "src/new.ts"]);
  });
});
