import { afterEach, expect, mock, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import * as repositories from "./git-repo-api";
import * as events from "../events/git-events";
import { createTag, deleteTag } from "./git-tags-api";
const spies: Array<{ mockRestore(): void }> = [];
afterEach(() => {
  spies.splice(0).forEach((spy) => spy.mockRestore());
});

const stubTagWrite = (write: (command: string, args: unknown) => Promise<unknown>) => {
  const invoke = mock(write);
  spies.push(spyOn(core, "invoke").mockImplementation(invoke as typeof core.invoke));
  spies.push(
    spyOn(repositories, "resolveRepositoryPathOrThrow").mockImplementation(async (path) => path),
  );
  spies.push(spyOn(events, "emitGitChanged").mockImplementation(() => {}));
  return invoke;
};

const commit = "a".repeat(40);

test("createTag writes through the shared Core createTag operation", async () => {
  const invoke = stubTagWrite(async () => null);

  await expect(
    createTag("C:/fixture", "light", undefined, commit, false, { lightweight: true }),
  ).resolves.toBe(true);
  // The tag manager leaves the target empty to mean HEAD; Core requires an
  // explicit revision, so the platform supplies the same default Git uses.
  await expect(createTag("C:/fixture", "legacy", undefined, undefined)).resolves.toBe(true);
  // A blank message stays lightweight, matching the legacy host behavior.
  await expect(createTag("C:/fixture", "blank", "   ", commit)).resolves.toBe(true);
  await expect(createTag("C:/fixture", "annotated", "release", commit, true)).resolves.toBe(true);

  expect(invoke.mock.calls).toEqual([
    [
      "git.write",
      {
        repoPath: "C:/fixture",
        operation: "createTag",
        name: "light",
        revision: commit,
        signed: false,
        lightweight: true,
      },
    ],
    [
      "git.write",
      {
        repoPath: "C:/fixture",
        operation: "createTag",
        name: "legacy",
        revision: "HEAD",
        signed: false,
      },
    ],
    [
      "git.write",
      {
        repoPath: "C:/fixture",
        operation: "createTag",
        name: "blank",
        revision: commit,
        signed: false,
      },
    ],
    [
      "git.write",
      {
        repoPath: "C:/fixture",
        operation: "createTag",
        name: "annotated",
        revision: commit,
        signed: true,
        message: "release",
      },
    ],
  ]);
});

test("deleteTag writes through the shared Core deleteTag operation", async () => {
  const invoke = stubTagWrite(async () => null);

  await expect(deleteTag("C:/fixture", "v1")).resolves.toBe(true);

  expect(invoke.mock.calls).toEqual([
    ["git.write", { repoPath: "C:/fixture", operation: "deleteTag", name: "v1" }],
  ]);
});

test("a rejected tag write is reported as false and keeps Git's reason in the console", async () => {
  const error = new Error("A tag named 'v1' already exists");
  stubTagWrite(async () => {
    throw error;
  });
  const log = spyOn(console, "error").mockImplementation(() => {});
  spies.push(log);

  await expect(createTag("C:/fixture", "v1")).resolves.toBe(false);
  expect(log).toHaveBeenCalledWith("Failed to create tag:", error);

  await expect(deleteTag("C:/fixture", "v1")).resolves.toBe(false);
  expect(log).toHaveBeenCalledWith("Failed to delete tag:", error);
});

test("a Git subprocess failure reported on the response is not counted as success", async () => {
  stubTagWrite(async () => ({ output: "gpg: signing failed: No secret key", exitCode: 1 }));
  const log = spyOn(console, "error").mockImplementation(() => {});
  spies.push(log);

  await expect(createTag("C:/fixture", "signed", "release", commit, true)).resolves.toBe(false);
  expect(log).toHaveBeenCalledWith(
    "Failed to create tag:",
    new Error("gpg: signing failed: No secret key"),
  );

  await expect(deleteTag("C:/fixture", "v1")).resolves.toBe(false);
  expect(log).toHaveBeenCalledWith(
    "Failed to delete tag:",
    new Error("gpg: signing failed: No secret key"),
  );
});
