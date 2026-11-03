import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { inspectShelfDiffs } from "./git-shelf-api";

let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
beforeEach(() => { invoke = spyOn(native, "invoke"); });
afterEach(() => invoke.mockRestore());

test("reads the complete shelf patch once through Core", async () => {
  const files = [{file_path: "a.txt", is_new: false, is_deleted: false, is_renamed: false, lines: []}];
  invoke.mockResolvedValue(files as never);
  const patch = "diff --git a/a.txt b/a.txt\ndiff --git a/b.txt b/b.txt\n";
  expect(await inspectShelfDiffs("C:/repo", patch, () => true)).toEqual(files);
  expect(invoke).toHaveBeenCalledTimes(1);
  expect(invoke).toHaveBeenCalledWith("git.parsePatch", {root: "C:/repo", patch});
});

test("drops a shelf response when the selected entry changes", async () => {
  let current = true;
  invoke.mockImplementation(async () => { current = false; return [{file_path: "stale"}] as never; });
  expect(await inspectShelfDiffs("C:/repo", "patch", () => current)).toEqual([]);
  expect(await inspectShelfDiffs("C:/repo", "patch", () => current)).toEqual([]);
  expect(invoke).toHaveBeenCalledTimes(1);
});
