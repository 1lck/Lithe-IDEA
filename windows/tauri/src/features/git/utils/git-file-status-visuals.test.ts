import { describe, expect, test } from "bun:test";
import {
  getCommitFileStatusColorClassName,
  getWorkingTreeStatusColorClassName,
} from "./git-file-status-visuals";

describe("Git file status visuals", () => {
  test("uses source-control colors for working-tree states", () => {
    expect(getWorkingTreeStatusColorClassName("added")).toBe("text-git-added");
    expect(getWorkingTreeStatusColorClassName("modified")).toBe("text-git-modified");
    expect(getWorkingTreeStatusColorClassName("deleted")).toBe("text-git-file-deleted");
    expect(getWorkingTreeStatusColorClassName("untracked")).toBe("text-git-untracked");
    expect(getWorkingTreeStatusColorClassName("renamed")).toBe("text-git-renamed");
  });

  test("uses matching colors for commit file status codes", () => {
    expect(getCommitFileStatusColorClassName("A")).toBe("text-git-added");
    expect(getCommitFileStatusColorClassName("M")).toBe("text-git-modified");
    expect(getCommitFileStatusColorClassName("D")).toBe("text-git-file-deleted");
    expect(getCommitFileStatusColorClassName("R100")).toBe("text-git-renamed");
    expect(getCommitFileStatusColorClassName("T")).toBe("text-foreground");
  });
});
