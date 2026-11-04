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

test("captures and executes the Core shelf plan before returning", async () => {
  const { shelveChanges } = await import("./git-shelf-api");
  const repoApi = await import("./git-repo-api");
  const resolve = spyOn(repoApi, "resolveRepositoryPathOrThrow").mockResolvedValue("C:/repo");
  const fixture = (await import("../../../../../../shared/fixtures/git/shelf-v1.json")).default;
  const calls: string[] = [];
  try {
    invoke.mockImplementation(async (command, args) => {
      if (command === "saved_changes_storage") { calls.push("save"); return undefined as never; }
      if (command !== "git.shelf") throw new Error(`unexpected command: ${command}`);
      const request = args as { action: string; phase?: string; layer?: string };
      calls.push(`${request.action}${request.layer ? `:${request.layer}` : ""}`);
      if (request.action === "capture") return fixture.capture as never;
      if (request.action === "plan") return fixture.cleanPlan as never;
      return {} as never;
    });
    const saved = await shelveChanges("C:/repo", "WIP", () => {});
    expect(saved.paths).toEqual(fixture.capture.paths);
    expect(calls).toEqual(["capture", "save", "plan", "clean:working", "clean:staged"]);
  } finally {
    resolve.mockRestore();
  }
});
