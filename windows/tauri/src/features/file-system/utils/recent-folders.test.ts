import { afterEach, describe, expect, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/workspace/recent-projects-v1.json";
import { useRecentFoldersStore } from "../stores/recent-folders.store";
import type { RecentFolder } from "../types/recent-folders.types";
import {
  applyRecentProjectsReduction,
  reduceRecentProjects,
  type RecentProjectsAction,
  type RecentProjectsReduction,
} from "./recent-folders";

type FixtureCase = (typeof fixture.cases)[number];

function folderFor(entry: FixtureCase["request"]["entries"][number]): RecentFolder {
  return {
    name: entry.path,
    path: entry.path,
    lastOpened: "stored",
    lastOpenedAt: "lastOpenedAt" in entry ? entry.lastOpenedAt : undefined,
    pinned: "pinned" in entry ? entry.pinned : undefined,
  };
}

/** Answers Core requests from the shared fixture, failing on any shape it does not contain. */
function mockCoreFromFixture() {
  return spyOn(core, "invoke").mockImplementation((async (command, payload) => {
    expect(command).toBe(fixture.command);
    const match = fixture.cases.find(
      (item) => !("capacity" in item.request) && Bun.deepEquals(item.request, payload),
    );
    if (!match) throw new Error(`No fixture case for ${JSON.stringify(payload)}`);
    return match.expected;
  }) as typeof core.invoke);
}

describe("recent projects use the shared Core reduction", () => {
  let invoke: ReturnType<typeof mockCoreFromFixture> | undefined;
  afterEach(() => invoke?.mockRestore());

  for (const item of fixture.cases.filter((entry) => !("capacity" in entry.request))) {
    test(item.name, async () => {
      invoke = mockCoreFromFixture();
      const folders = item.request.entries.map(folderFor);
      const reduction = await reduceRecentProjects(
        folders,
        item.request.action as RecentProjectsAction,
      );
      const applied = applyRecentProjectsReduction(folders, reduction);
      expect(applied.map(({ path, lastOpenedAt, pinned }) => ({ path, lastOpenedAt, pinned }))).toEqual(
        item.expected.entries.map(({ path, lastOpenedAt, pinned }) => ({
          path,
          lastOpenedAt,
          pinned: pinned || undefined,
        })),
      );
    });
  }

  test("reductions keep metadata edited while a reduction was pending", async () => {
    const previous = useRecentFoldersStore.getState().recentFolders;
    let release: (value: RecentProjectsReduction) => void = () => {};
    invoke = spyOn(core, "invoke").mockImplementation(
      (() => new Promise((resolve) => (release = resolve as typeof release))) as typeof core.invoke,
    );
    try {
      useRecentFoldersStore.setState({
        recentFolders: [{ name: "a", path: "/a", lastOpened: "x", lastOpenedAt: 1 }],
      });
      const pending = useRecentFoldersStore.getState().actions.togglePinned("/a");
      useRecentFoldersStore.getState().actions.updateRecentFolder("/a", { customIcon: "star" });
      await Promise.resolve();
      release({ entries: [{ path: "/a", lastOpenedAt: 1, pinned: true }], added: [], removed: [] });
      await pending;
      expect(useRecentFoldersStore.getState().recentFolders).toEqual([
        { name: "a", path: "/a", lastOpened: "x", lastOpenedAt: 1, pinned: true, customIcon: "star" },
      ]);
    } finally {
      useRecentFoldersStore.setState({ recentFolders: previous });
    }
  });

  test("a failed reduction keeps the stored list", async () => {
    const previous = useRecentFoldersStore.getState().recentFolders;
    const consoleError = spyOn(console, "error").mockImplementation(() => {});
    invoke = spyOn(core, "invoke").mockRejectedValue(new Error("core unavailable"));
    try {
      const stored = [{ name: "a", path: "/a", lastOpened: "x", lastOpenedAt: 1 }];
      useRecentFoldersStore.setState({ recentFolders: stored });
      await useRecentFoldersStore.getState().actions.addToRecents("/b");
      expect(useRecentFoldersStore.getState().recentFolders).toEqual(stored);
      expect(consoleError).toHaveBeenCalledTimes(1);
    } finally {
      consoleError.mockRestore();
      useRecentFoldersStore.setState({ recentFolders: previous });
    }
  });
});
