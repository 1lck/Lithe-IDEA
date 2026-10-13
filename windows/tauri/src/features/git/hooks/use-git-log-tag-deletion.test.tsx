import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { toast } from "sonner";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitReference } from "../types/git.types";
import { useGitLogTagDeletion } from "./use-git-log-tag-deletion";

const dialogs = await import("@/ui/dialog");
const tagsApi = await import("../api/git-tags-api");
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let current: ReturnType<typeof useGitLogTagDeletion> | null;
const spies: Array<{ mockRestore: () => void }> = [];
const deletions: Array<(deleted: boolean) => void> = [];
const operations: Promise<void>[] = [];
const confirm = mock(
  async (..._args: Parameters<typeof dialogs.showConfirmDialog>): Promise<boolean> => {
    throw new Error("Tag deletion must not ask for a second confirmation");
  },
);
const deleteTag = mock(
  (..._args: Parameters<typeof tagsApi.deleteTag>) =>
    new Promise<boolean>((resolve) => deletions.push(resolve)),
);
const onDeleted = mock(async (_reference: GitReference) => {});
const success = mock((..._args: Parameters<typeof toast.success>) => "toast");
const failure = mock((..._args: Parameters<typeof toast.error>) => "toast");
const tag: GitReference = {
  kind: "tag",
  fullName: "refs/tags/release/v1",
  shortName: "release/v1",
  peelsToCommit: true,
  isCurrent: false,
  repositoryPath: "C:/repo-a",
};

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  current = null;
  confirm.mockClear();
  deleteTag.mockClear();
  onDeleted.mockClear();
  success.mockClear();
  failure.mockClear();
  spies.push(
    spyOn(dialogs, "showConfirmDialog").mockImplementation(confirm),
    spyOn(tagsApi, "deleteTag").mockImplementation(deleteTag),
    spyOn(toast, "success").mockImplementation(success),
    spyOn(toast, "error").mockImplementation(failure),
  );
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    // Unmount first, then release all controlled work so even failed assertions
    // cannot leave a deletion promise hanging.
    await act(async () => {
      root.unmount();
      for (const resolve of deletions.splice(0)) resolve(false);
      await Promise.all(operations.splice(0));
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

function Probe({
  repoPath,
  workspaceId,
  isBlocked,
}: {
  repoPath: string;
  workspaceId: string;
  isBlocked: boolean;
}) {
  current = useGitLogTagDeletion({
    repoPath,
    scope: `${workspaceId}\0${repoPath}`,
    isBlocked,
    onDeleted,
  });
  return null;
}
const render = async (repoPath = "C:/repo-a", workspaceId = "workspace-a", isBlocked = false) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <Probe repoPath={repoPath} workspaceId={workspaceId} isBlocked={isBlocked} />
      </LocaleProvider>,
    ),
  );
};
const read = () => {
  if (!current) throw new Error("Deletion hook is not mounted");
  return current;
};
const start = async (reference = tag) =>
  act(async () => {
    operations.push(read().deleteTagReference(reference));
  });
const release = async (queue: Array<(value: boolean) => void>, value: boolean) => {
  const resolve = queue.shift();
  if (!resolve) throw new Error("No pending controlled operation");
  await act(async () => resolve(value));
};

test("starts deletion immediately without a second confirmation", async () => {
  await render();
  await start();
  expect(read().isDeletingTag).toBe(true);
  expect(confirm).not.toHaveBeenCalled();
  expect(deleteTag.mock.calls).toEqual([["C:/repo-a", "release/v1"]]);
  expect(onDeleted).not.toHaveBeenCalled();
  await release(deletions, true);
  expect(onDeleted.mock.calls).toEqual([[tag]]);
  expect(read().isDeletingTag).toBe(false);
});

test("deletes only the selected local tag and rejects repeated requests", async () => {
  await render();
  await start();
  await start();
  expect(confirm).not.toHaveBeenCalled();
  expect(deleteTag.mock.calls).toEqual([["C:/repo-a", "release/v1"]]);
  await start();
  expect(deleteTag).toHaveBeenCalledTimes(1);
  await release(deletions, true);
  expect(onDeleted.mock.calls).toEqual([[tag]]);
  expect(success).toHaveBeenCalledTimes(1);
  expect(read().isDeletingTag).toBe(false);
});

test("a failed deletion keeps the reference and permits retry", async () => {
  await render();
  await start();
  await release(deletions, false);
  expect(onDeleted).not.toHaveBeenCalled();
  expect(success).not.toHaveBeenCalled();
  expect(failure).toHaveBeenCalledTimes(1);
  expect(read().isDeletingTag).toBe(false);
  await start();
  await release(deletions, true);
  expect(onDeleted).toHaveBeenCalledTimes(1);
});

test("a handler from the previous workspace cannot start a deletion", async () => {
  await render();
  const previousHandler = read().deleteTagReference;
  await render("C:/repo-a", "workspace-b");
  await act(async () => operations.push(previousHandler(tag)));
  expect(deleteTag).not.toHaveBeenCalled();
  expect(onDeleted).not.toHaveBeenCalled();
  expect(read().isDeletingTag).toBe(false);
});

test("late deletion cannot refresh another repository or release its active request", async () => {
  await render();
  await start();
  await render("C:/repo-b");
  const nextTag = { ...tag, repositoryPath: "C:/repo-b" };
  await start(nextTag);
  await release(deletions, true);
  expect(onDeleted).not.toHaveBeenCalled();
  expect(success).not.toHaveBeenCalled();
  expect(read().isDeletingTag).toBe(true);
  await release(deletions, true);
  expect(onDeleted.mock.calls).toEqual([[nextTag]]);
  expect(read().isDeletingTag).toBe(false);
});

test("blocked actions and references from another repository cannot delete tags", async () => {
  await render("C:/repo-a", "workspace-a", true);
  await start();
  await render();
  const previousHandler = read().deleteTagReference;
  await start({ ...tag, repositoryPath: "C:/repo-b" });
  await start({ ...tag, kind: "local" });
  expect(confirm).not.toHaveBeenCalled();
  await render("C:/repo-a", "workspace-a", true);
  await act(async () => operations.push(previousHandler(tag)));
  expect(deleteTag).not.toHaveBeenCalled();
  expect(read().isDeletingTag).toBe(false);
});
