import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialogs from "@/ui/dialog";
import * as shelfApi from "../../api/git-shelf-api";
import * as stashApi from "../../api/git-stash-api";
import * as diffApi from "../../api/git-diff-api";
import type { GitShelf } from "../../services/git-shelf-workflow";
import { useGitSavedChangesOperations } from "../../hooks/use-git-saved-changes-operations";
import { GitSavedChanges } from "./git-saved-changes";

const repoA = "C:/fixture/repository-a";
const repoB = "C:/fixture/repository-b";
const shelf = (message: string): GitShelf => ({
  version: 1,
  id: "00000000-0000-4000-8000-000000000001",
  message,
  createdAt: 123,
  stagedPatch: "staged",
  workingPatch: "worktree",
  paths: ["file.txt"],
});
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const spies: Array<{ mockRestore(): void }> = [];
const releases: Array<() => void> = [];
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let list: ReturnType<typeof spyOn<typeof shelfApi, "listShelves">>;
let restore: ReturnType<typeof spyOn<typeof shelfApi, "restoreShelf">>;
let remove: ReturnType<typeof spyOn<typeof shelfApi, "deleteShelf">>;
let confirm: ReturnType<typeof spyOn<typeof dialogs, "showConfirmDialog">>;
let refreshes: number;
let busy: boolean;

function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  releases.push(() => resolve(fallback));
  return { promise, resolve, reject };
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  refreshes = 0;
  busy = false;
  list = spyOn(shelfApi, "listShelves").mockResolvedValue([shelf("A shelf")]);
  restore = spyOn(shelfApi, "restoreShelf").mockResolvedValue(undefined);
  remove = spyOn(shelfApi, "deleteShelf").mockResolvedValue(undefined);
  confirm = spyOn(dialogs, "showConfirmDialog").mockResolvedValue(true);
  spies.push(
    list,
    restore,
    remove,
    confirm,
    spyOn(shelfApi, "assertSavedFiles").mockImplementation(() => {}),
    spyOn(shelfApi, "inspectShelfDiffs").mockResolvedValue([]),
    spyOn(stashApi, "getStashes").mockResolvedValue([]),
    spyOn(diffApi, "getStashDiff").mockResolvedValue([]),
  );
});

afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const release of releases.splice(0)) release();
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    restoreDom();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

function SavedChangesPanel({
  repository,
  showSaved,
}: {
  repository: string;
  showSaved: boolean;
}) {
  const operations = useGitSavedChangesOperations(repository);
  busy = operations.busy;
  return (
    <>
      <button disabled={operations.workspaceBusy}>Commit</button>
      <button disabled={operations.busy}>Switch tab</button>
      {showSaved && (
        <GitSavedChanges
          root={repository}
          operationBusy={operations.busy}
          onOperationStart={() => operations.startOperation(repository)}
          onRefresh={() => {
            refreshes++;
          }}
        />
      )}
    </>
  );
}

async function render(repository: string, showSaved = true) {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <SavedChangesPanel repository={repository} showSaved={showSaved} />
      </LocaleProvider>,
    ),
  );
}

function button(label: string) {
  const result = [...container.querySelectorAll<HTMLButtonElement>("button")].find((element) =>
    element.getAttribute("role") === "treeitem"
      ? element.textContent?.startsWith(label)
      : (element.getAttribute("aria-label") ?? element.textContent?.trim()) === label,
  );
  expect(result).toBeDefined();
  return result!;
}

async function click(label: string) {
  await act(async () => button(label).click());
}

test("switching repositories hides stale shelves through pending and failed loads, then permits retry", async () => {
  await render(repoA);
  await click("A shelf");
  const oldRow = button("A shelf");
  const oldRestore = button("Restore");
  const pending = deferred<GitShelf[]>([]);
  list.mockImplementation((repository) =>
    repository === repoB ? pending.promise : Promise.resolve([shelf("A shelf")]),
  );
  await render(repoB);
  expect(container.textContent).not.toContain("A shelf");
  expect(container.textContent).not.toContain("Restore");
  expect(button("Shelve\u2026").disabled).toBe(true);
  await act(async () => {
    oldRow.click();
    oldRestore.click();
  });
  expect(restore).not.toHaveBeenCalled();
  expect(remove).not.toHaveBeenCalled();
  await act(async () => pending.reject(new Error("B list failed")));
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("Error: B list failed");
  expect(container.textContent).not.toContain("A shelf");
  expect(button("Shelve\u2026").disabled).toBe(true);
  expect(button("Refresh").disabled).toBe(false);
  list.mockResolvedValue([shelf("B shelf")]);
  await click("Refresh");
  await click("B shelf");
  await click("Restore");
  expect(restore).toHaveBeenCalledTimes(1);
  expect(restore.mock.calls[0]!.slice(0, 2)).toEqual([repoB, shelf("B shelf")]);
  expect(refreshes).toBe(1);
  expect(busy).toBe(false);
});

for (const outcome of ["success", "failure"] as const) {
  test(`a late ${outcome} from the previous repository cannot replace current shelves`, async () => {
    const old = deferred<GitShelf[]>([]);
    list.mockImplementation((repository) =>
      repository === repoA ? old.promise : Promise.resolve([shelf("B shelf")]),
    );
    await render(repoA);
    expect(button("Shelve\u2026").disabled).toBe(true);
    await render(repoB);
    await act(async () => {
      if (outcome === "success") old.resolve([shelf("A shelf")]);
      else old.reject(new Error("old failure"));
    });
    expect(container.textContent).toContain("B shelf");
    expect(container.textContent).not.toContain("A shelf");
    expect(container.querySelector('[role="alert"]')).toBeNull();
    await click("B shelf");
    await click("Delete");
    expect(remove.mock.calls).toEqual([[repoB, shelf("B shelf").id]]);
  });
}

test("refresh failures cannot leave a previous shelf selectable for mutation", async () => {
  await render(repoA);
  await click("A shelf");
  const pending = deferred<GitShelf[]>([]);
  list.mockReturnValue(pending.promise);
  await click("Refresh");
  expect(container.textContent).not.toContain("A shelf");
  expect(container.textContent).not.toContain("Restore");
  await act(async () => pending.reject(new Error("read failed")));
  expect(container.textContent).not.toContain("A shelf");
  expect(restore).not.toHaveBeenCalled();
  expect(remove).not.toHaveBeenCalled();
});

for (const returnToA of [false, true]) {
  test(`a pending delete confirmation cannot outlive its repository session (return=${returnToA})`, async () => {
    const approval = deferred(false);
    confirm.mockReturnValue(approval.promise);
    await render(repoA);
    await click("A shelf");
    await click("Delete");
    expect(confirm).toHaveBeenCalledTimes(1);
    await render(repoB);
    if (returnToA) await render(repoA);
    await act(async () => approval.resolve(true));
    expect(remove).not.toHaveBeenCalled();
    expect(restore).not.toHaveBeenCalled();
    expect(refreshes).toBe(0);
    expect(busy).toBe(false);
  });
}

test("restoration guards stay invalid after leaving and returning to the same repository", async () => {
  const apply = deferred(undefined);
  const writes: string[] = [];
  restore.mockImplementation(async (repository, _entry, guard) => {
    await apply.promise;
    guard();
    writes.push(repository);
  });
  await render(repoA);
  await click("A shelf");
  await click("Restore");
  expect(restore).toHaveBeenCalledTimes(1);
  await render(repoB);
  await render(repoA);
  await act(async () => apply.resolve(undefined));
  expect(writes).toEqual([]);
  expect(remove).not.toHaveBeenCalled();
  expect(refreshes).toBe(0);
  expect(busy).toBe(false);
});

for (const outcome of ["success", "failure"] as const) {
  test(`a late ${outcome} after remount cannot unlock another repository's pending operation`, async () => {
    const oldApply = deferred(undefined);
    const newApply = deferred(undefined);
    list.mockImplementation((repository) =>
      Promise.resolve([shelf(repository === repoA ? "A shelf" : "B shelf")]),
    );
    restore.mockImplementation((repository) =>
      repository === repoA ? oldApply.promise : newApply.promise,
    );
    await render(repoA);
    await click("A shelf");
    await click("Restore");
    expect(button("Commit").disabled).toBe(true);

    // The parent survives a repository/tab switch while the old child is unmounted.
    await render(repoB, false);
    expect(button("Commit").disabled).toBe(true);
    expect(button("Switch tab").disabled).toBe(false);
    await render(repoB);
    await click("B shelf");
    await click("Restore");
    expect(restore).toHaveBeenCalledTimes(2);
    await act(async () => {
      if (outcome === "success") oldApply.resolve(undefined);
      else oldApply.reject(new Error("old operation failed"));
    });
    expect(button("Commit").disabled).toBe(true);
    expect(button("Shelve\u2026").disabled).toBe(true);
    expect(refreshes).toBe(0);
    expect(container.querySelector('[role="alert"]')).toBeNull();

    await act(async () => newApply.resolve(undefined));
    expect(button("Commit").disabled).toBe(false);
    expect(refreshes).toBe(1);
  });
}

test("returning to an unmounted repository retains its lock until its operation settles", async () => {
  const oldApply = deferred(undefined);
  restore.mockReturnValue(oldApply.promise);
  await render(repoA);
  await click("A shelf");
  await click("Restore");
  await render(repoB, false);
  expect(button("Commit").disabled).toBe(true);
  expect(button("Switch tab").disabled).toBe(false);
  await render(repoA);
  expect(button("Commit").disabled).toBe(true);
  expect(button("A shelf").disabled).toBe(true);
  expect(button("Shelve\u2026").disabled).toBe(true);
  await click("Shelve\u2026");
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(restore).toHaveBeenCalledTimes(1);

  await act(async () => oldApply.resolve(undefined));
  expect(button("Commit").disabled).toBe(false);
  expect(button("A shelf").disabled).toBe(false);
  expect(refreshes).toBe(0);
});

for (const outcome of ["success", "failure"] as const) {
  test(`switching sidebars retains a pending operation through full parent unmount (${outcome})`, async () => {
    const pendingApply = deferred(undefined);
    restore.mockReturnValue(pendingApply.promise);
    await render(repoA);
    await click("A shelf");
    await click("Restore");

    // MainSidebar renders only its active pane, so switching to Files removes the parent too.
    await act(async () => root.render(<div>Project</div>));
    await render(repoA);
    expect(button("Commit").disabled).toBe(true);
    expect(button("Switch tab").disabled).toBe(true);
    expect(button("A shelf").disabled).toBe(true);
    await click("Shelve\u2026");
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(restore).toHaveBeenCalledTimes(1);

    await act(async () => {
      if (outcome === "success") pendingApply.resolve(undefined);
      else pendingApply.reject(new Error("operation failed after sidebar switch"));
    });
    expect(button("Commit").disabled).toBe(false);
    expect(button("A shelf").disabled).toBe(false);
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(refreshes).toBe(0);
  });
}

test("a remounted pane reloads shelves when an earlier pane's native deletion finishes", async () => {
  const deletion = deferred(undefined);
  let entries = [shelf("A shelf")];
  list.mockImplementation(async () => entries);
  remove.mockImplementation(async () => {
    await deletion.promise;
    entries = [];
  });
  await render(repoA);
  await click("A shelf");
  await click("Delete");
  expect(remove).toHaveBeenCalledTimes(1);

  await act(async () => root.render(<div>Project</div>));
  await render(repoA);
  expect(button("A shelf").disabled).toBe(true);
  expect(button("Commit").disabled).toBe(true);

  await act(async () => deletion.resolve(undefined));
  expect(button("Commit").disabled).toBe(false);
  expect(container.textContent).not.toContain("A shelf");
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(refreshes).toBe(0);
});

test("an already-dispatched deletion reloads shelves after A -> B -> A without unmounting", async () => {
  const deletion = deferred(undefined);
  let entries = [shelf("A shelf")];
  list.mockImplementation(async (repository) => (repository === repoA ? entries : []));
  remove.mockImplementation(async () => {
    await deletion.promise;
    entries = [];
  });
  await render(repoA);
  await click("A shelf");
  await click("Delete");
  expect(remove).toHaveBeenCalledTimes(1);

  await render(repoB);
  await render(repoA);
  expect(button("A shelf").disabled).toBe(true);
  expect(button("Commit").disabled).toBe(true);

  await act(async () => deletion.resolve(undefined));
  expect(button("Commit").disabled).toBe(false);
  expect(container.textContent).not.toContain("A shelf");
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(refreshes).toBe(0);
});
