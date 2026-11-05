import { afterEach, expect, mock, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import type { GitReference } from "../types/git.types";
import { previewBranchName } from "./git-branch-name";

const spies: Array<{ mockRestore(): void }> = [];
afterEach(() => {
  spies.splice(0).forEach((spy) => spy.mockRestore());
});

const reference = (kind: GitReference["kind"], shortName: string): GitReference => ({
  fullName: kind === "remote" ? `refs/remotes/${shortName}` : `refs/heads/${shortName}`,
  shortName,
  kind,
  peelsToCommit: true,
  isCurrent: false,
});

test("previews through Core sending only the reference facts it validates", async () => {
  const preview = {
    typingCleanedName: "feature-foo",
    cleanedName: "feature-foo",
    initialName: "main",
    error: null,
  };
  const invoke = mock(async (_command: string, _args: unknown) => preview);
  spies.push(spyOn(core, "invoke").mockImplementation(invoke as typeof core.invoke));

  await expect(
    previewBranchName({
      rawName: "feature foo",
      requireName: true,
      references: [reference("local", "main"), reference("local", "feature/login")],
      reference: reference("remote", "origin/main"),
    }),
  ).resolves.toEqual(preview);

  expect(invoke.mock.calls).toEqual([
    [
      "git.branchNamePreview",
      {
        rawName: "feature foo",
        requireName: true,
        references: [
          { kind: "local", shortName: "main" },
          { kind: "local", shortName: "feature/login" },
        ],
        reference: { kind: "remote", shortName: "origin/main" },
      },
    ],
  ]);
});

test("omits the optional reference when the dialog has no starting point", async () => {
  const invoke = mock(async () => ({
    typingCleanedName: "",
    cleanedName: "",
    initialName: "",
    error: { code: "empty" },
  }));
  spies.push(spyOn(core, "invoke").mockImplementation(invoke as typeof core.invoke));

  const result = await previewBranchName({
    rawName: "",
    requireName: true,
    references: [reference("local", "main")],
  });

  expect(result.error).toEqual({ code: "empty" });
  expect(invoke).toHaveBeenCalledWith("git.branchNamePreview", {
    rawName: "",
    requireName: true,
    references: [{ kind: "local", shortName: "main" }],
  });
});
