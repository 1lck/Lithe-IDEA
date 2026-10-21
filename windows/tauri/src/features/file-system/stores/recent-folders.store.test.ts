import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import * as platform from "@/features/file-system/controllers/platform";
import * as dialog from "@/ui/dialog";
import { useRecentFoldersStore } from "./recent-folders.store";

const STALE_PATH = "D:\\work\\moved\\project";

describe("openRecentFolder with an unavailable project", () => {
  let previousRecentFolders: ReturnType<typeof useRecentFoldersStore.getState>["recentFolders"];
  let confirm: ReturnType<typeof spyOn<typeof dialog, "showConfirmDialog">>;
  let symlinkInfo: ReturnType<typeof spyOn<typeof platform, "getSymlinkInfo">>;
  let consoleError: ReturnType<typeof spyOn<typeof console, "error">>;

  beforeEach(() => {
    previousRecentFolders = useRecentFoldersStore.getState().recentFolders;
    useRecentFoldersStore.setState({
      recentFolders: [
        { name: "project", path: STALE_PATH, lastOpened: "2026-01-01T00:00:00.000Z" },
        { name: "other", path: "D:\\work\\other", lastOpened: "2026-01-01T00:00:00.000Z" },
      ],
    });
    confirm = spyOn(dialog, "showConfirmDialog").mockResolvedValue(false);
    symlinkInfo = spyOn(platform, "getSymlinkInfo").mockRejectedValue(new Error("not found"));
    // The store logs the underlying failure; keep expected errors out of the test output.
    consoleError = spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    confirm.mockRestore();
    symlinkInfo.mockRestore();
    consoleError.mockRestore();
    useRecentFoldersStore.setState({ recentFolders: previousRecentFolders });
  });

  test("removes the entry when the user confirms the removal", async () => {
    confirm.mockResolvedValue(true);

    await useRecentFoldersStore.getState().actions.openRecentFolder(STALE_PATH);

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(String(confirm.mock.calls[0]?.[0])).toContain(STALE_PATH);
    expect(useRecentFoldersStore.getState().recentFolders.map((folder) => folder.path)).toEqual([
      "D:\\work\\other",
    ]);
  });

  test("keeps the entry, flagged missing, when the user cancels", async () => {
    await useRecentFoldersStore.getState().actions.openRecentFolder(STALE_PATH);

    expect(confirm).toHaveBeenCalledTimes(1);
    const entry = useRecentFoldersStore
      .getState()
      .recentFolders.find((folder) => folder.path === STALE_PATH);
    expect(entry?.missing).toBe(true);
  });

  test("offers the same removal when the path is no longer a folder", async () => {
    symlinkInfo.mockResolvedValue({ is_dir: false } as Awaited<
      ReturnType<typeof platform.getSymlinkInfo>
    >);
    confirm.mockResolvedValue(true);

    await useRecentFoldersStore.getState().actions.openRecentFolder(STALE_PATH);

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(useRecentFoldersStore.getState().recentFolders.map((folder) => folder.path)).toEqual([
      "D:\\work\\other",
    ]);
  });
});
