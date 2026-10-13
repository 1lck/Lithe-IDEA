import { afterEach, expect, mock, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import * as repositories from "./git-repo-api";
import * as events from "../events/git-events";
import { createTag } from "./git-tags-api";
const spies: Array<{ mockRestore(): void }> = [];
afterEach(() => {
  spies.splice(0).forEach((spy) => spy.mockRestore());
});
test("Only explicit lightweight tags override the existing signing policy", async () => {
  const invoke = mock(async (_command: string, _args: unknown) => null);
  spies.push(spyOn(core, "invoke").mockImplementation(invoke as typeof core.invoke));
  spies.push(
    spyOn(repositories, "resolveRepositoryPathOrThrow").mockImplementation(async (path) => path),
  );
  spies.push(spyOn(events, "emitGitChanged").mockImplementation(() => {}));
  const commit = "a".repeat(40);
  await expect(
    createTag("C:/fixture", "light", undefined, commit, false, { lightweight: true }),
  ).resolves.toBe(true);
  await expect(createTag("C:/fixture", "legacy", undefined, commit)).resolves.toBe(true);
  expect(invoke.mock.calls).toEqual([
    [
      "git_create_tag",
      {
        repoPath: "C:/fixture",
        name: "light",
        message: undefined,
        commit,
        signed: false,
        lightweight: true,
      },
    ],
    [
      "git_create_tag",
      { repoPath: "C:/fixture", name: "legacy", message: undefined, commit, signed: false },
    ],
  ]);
});
