import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialogs from "@/ui/dialog";
import * as paneSync from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import * as commitsApi from "../api/git-commits-api";
import * as diffApi from "../api/git-diff-api";
import type { GitCommit, GitDiff } from "../types/git.types";
import { useGitDiffActions } from "./use-git-diff-actions";

const commit = (hash: string): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes: [],
  message: hash,
  author: "Developer",
  date: "2026/09/01",
  decorations: "",
});
const commits = new Map(["first", "second"].map((hash) => [hash, commit(hash)]));
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let actions: ReturnType<typeof useGitDiffActions>;
let openBuffer: ReturnType<typeof spyOn>;
const spies: Array<{ mockRestore(): void }> = [];
const pending = new Map<string, () => void>();
const requests: Promise<void>[] = [];

function Harness({ repo }: { repo: string }) {
  actions = useGitDiffActions({
    activeRepoPath: repo,
    commitByHash: commits,
    gitFileByPath: new Map(),
    workingTreeDiffEntriesByScope: { all: [], staged: [], unstaged: [] },
  });
  return null;
}
async function render(repo = "C:/repo-a") {
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <Harness repo={repo} />
      </LocaleProvider>,
    );
  });
}
async function start(hash: string) {
  await act(async () => {
    requests.push(actions.viewCommitDiff(hash));
    await Promise.resolve();
  });
  expect(pending.has(hash)).toBe(true);
}
async function finish(hash: string) {
  const release = pending.get(hash);
  if (!release) throw new Error(`Missing pending message for ${hash}`);
  await act(async () => {
    release();
    await Promise.resolve();
  });
  pending.delete(hash);
}

beforeEach(() => {
  restoreDom = installHappyDom();
  originalAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  openBuffer = spyOn(useBufferStore.getState().actions, "openBuffer").mockReturnValue(
    "diff-buffer",
  );
  spies.push(
    openBuffer,
    spyOn(dialogs, "showAlertDialog").mockResolvedValue(undefined),
    spyOn(paneSync, "activateMainEditorPane").mockReturnValue(null),
    spyOn(diffApi, "getCommitDiff").mockResolvedValue([
      { file_path: "file.txt", lines: [], is_new: false, is_deleted: false, is_renamed: false },
    ] satisfies GitDiff[]),
    spyOn(commitsApi, "withCommitDescription").mockImplementation(
      (_repo, selected) =>
        new Promise((resolve) =>
          pending.set(selected.hash, () =>
            resolve({ ...selected, description: `Body ${selected.hash}` }),
          ),
        ),
    ),
  );
});
afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const release of pending.values()) release();
      await Promise.all(requests);
    });
  } finally {
    pending.clear();
    requests.length = 0;
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    restoreDom();
    if (originalAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = originalAct;
  }
});

test("opens the selected commit diff with its loaded message", async () => {
  await render();
  await start("first");
  await finish("first");
  expect(openBuffer).toHaveBeenCalledTimes(1);
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({
    commitDescription: "Body first",
    repoPath: "C:/repo-a",
  });
  expect(actions.isLoadingCommitDiff).toBe(false);
});
test("late message cannot open an old diff or clear the newer loading state", async () => {
  await render();
  await start("first");
  await start("second");
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
  expect(actions.isLoadingCommitDiff).toBe(true);
  await finish("second");
  expect(openBuffer).toHaveBeenCalledTimes(1);
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({ commitDescription: "Body second" });
});
test("switching repositories invalidates a pending message even when returning to the original", async () => {
  await render();
  await start("first");
  await render("C:/repo-b");
  await render();
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
  expect(actions.isLoadingCommitDiff).toBe(false);
});
test("unmount prevents a pending message from opening an editor", async () => {
  await render();
  await start("first");
  await act(async () => {
    root.render(null);
  });
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
});
