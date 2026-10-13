import { describe, expect, test } from "bun:test";
import { buildGitRepositoryContextMenuItems } from "./file-context-menu-git-items";

const labels = {
  submenu: "Git",
  openGitLog: "Open Git Log",
  fetch: "Fetch",
  pull: "Pull…",
  push: "Push…",
  newBranch: "New Branch…",
};

const noop = () => {};

describe("buildGitRepositoryContextMenuItems", () => {
  test("builds a single Git submenu with the expected actions", () => {
    const items = buildGitRepositoryContextMenuItems({
      labels,
      actions: {
        openGitLog: noop,
        fetch: noop,
        pull: noop,
        push: noop,
        newBranch: noop,
      },
    });

    expect(items).toHaveLength(1);
    expect(items[0].id).toBe("git");
    expect(items[0].label).toBe("Git");
    expect(items[0].children?.map((item) => item.id)).toEqual([
      "git-open-log",
      "git-fetch",
      "git-pull",
      "git-push",
      "git-new-branch",
    ]);
    expect(items[0].children?.map((item) => item.label)).toEqual([
      "Open Git Log",
      "Fetch",
      "Pull…",
      "Push…",
      "New Branch…",
    ]);
  });

  test("disables the submenu and every action while an operation runs", () => {
    const items = buildGitRepositoryContextMenuItems({
      labels,
      actions: { openGitLog: noop, fetch: noop, pull: noop, push: noop, newBranch: noop },
      disabled: true,
    });

    expect(items[0].disabled).toBe(true);
    expect(items[0].children?.every((item) => item.disabled)).toBe(true);
  });

  test("routes each action to the matching callback", () => {
    const calls: string[] = [];
    const items = buildGitRepositoryContextMenuItems({
      labels,
      actions: {
        openGitLog: () => calls.push("openGitLog"),
        fetch: () => calls.push("fetch"),
        pull: () => calls.push("pull"),
        push: () => calls.push("push"),
        newBranch: () => calls.push("newBranch"),
      },
    });

    for (const item of items[0].children ?? []) item.onClick();
    expect(calls).toEqual(["openGitLog", "fetch", "pull", "push", "newBranch"]);
  });
});
