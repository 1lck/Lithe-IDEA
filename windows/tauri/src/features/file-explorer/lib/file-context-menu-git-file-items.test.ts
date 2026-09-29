import { describe, expect, test } from "bun:test";
import {
  buildGitFileContextMenuItems,
  getExplorerGitFileMenuCapabilities,
  type ExplorerGitFileMenuCapabilities,
} from "./file-context-menu-git-file-items";

const noOpAction = () => {};

function buildItems(capabilities: ExplorerGitFileMenuCapabilities) {
  return buildGitFileContextMenuItems({
    labels: {
      submenu: "Git",
      showDiff: "Show Diff",
      add: "Add",
      commitFile: "Commit File…",
    },
    actions: {
      showDiff: noOpAction,
      add: noOpAction,
      commitFile: noOpAction,
    },
    capabilities,
  });
}

describe("getExplorerGitFileMenuCapabilities", () => {
  test("returns no capabilities without a Git change entry", () => {
    expect(getExplorerGitFileMenuCapabilities(null)).toEqual({
      showDiff: false,
      add: false,
      commitFile: false,
    });
  });

  test("untracked files can be diffed, added and committed", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "untracked", staged: false })).toEqual({
      showDiff: true,
      add: true,
      commitFile: true,
    });
  });

  test("unstaged modifications keep the add action", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "modified", staged: false }).add).toBe(
      true,
    );
  });

  test("staged entries hide the add action because staging again is a no-op", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "modified", staged: true }).add).toBe(
      false,
    );
    expect(getExplorerGitFileMenuCapabilities({ status: "added", staged: true }).add).toBe(false);
  });

  test("deleted and renamed entries still support diff and commit", () => {
    expect(getExplorerGitFileMenuCapabilities({ status: "deleted", staged: false })).toEqual({
      showDiff: true,
      add: true,
      commitFile: true,
    });
    expect(getExplorerGitFileMenuCapabilities({ status: "renamed", staged: true }).showDiff).toBe(
      true,
    );
  });
});

describe("buildGitFileContextMenuItems", () => {
  test("renders a Git submenu with every enabled action", () => {
    const items = buildItems({ showDiff: true, add: true, commitFile: true });

    expect(items).toHaveLength(1);
    expect(items[0].id).toBe("git-file");
    expect(items[0].children?.map((child) => child.id)).toEqual([
      "git-show-diff",
      "git-add",
      "git-commit-file",
    ]);
  });

  test("omits disabled actions from the submenu", () => {
    const items = buildItems({ showDiff: true, add: false, commitFile: true });

    expect(items[0].children?.map((child) => child.id)).toEqual([
      "git-show-diff",
      "git-commit-file",
    ]);
  });

  test("returns no submenu when no capability applies", () => {
    expect(buildItems({ showDiff: false, add: false, commitFile: false })).toEqual([]);
  });
});
