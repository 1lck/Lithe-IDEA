import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as api from "../api/git-diff-api";
import type { GitCommit, GitDiff } from "../types/git.types";
import type { MultiFileDiff } from "../types/git-diff.types";
import { useCommitFilePreview } from "./use-commit-file-preview";

const commit = (hash: string): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes: [],
  message: hash,
  author: "Test",
  date: "",
  decorations: "",
});
const diff = (additions: number, path = "a.ts"): GitDiff => ({
  file_path: path,
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
  additions,
  deletions: 0,
});
let preview: ReturnType<typeof useCommitFilePreview>;
let root: Root | undefined;
let container: HTMLElement;
let restoreDom: () => void;
let previousAct: boolean | undefined;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let published: MultiFileDiff[];
let releases: Array<() => void>;
let inFlight: Promise<void>[];
let loadCommit: ReturnType<typeof spyOn<typeof api, "getCommitDiff">>;
let loadRange: ReturnType<typeof spyOn<typeof api, "getRefDiff">>;
const openPreview = (_path: string, _name: string, data: MultiFileDiff) => {
  published.push(data);
};

function Harness({ scope = "A", repo = "C:/repo" }: { scope?: string | null; repo?: string }) {
  preview = useCommitFilePreview(repo, scope, openPreview);
  return null;
}
async function render(scope: string | null, repo = "C:/repo") {
  await act(async () => {
    root!.render(<Harness scope={scope} repo={repo} />);
  });
}
function pendingDiff() {
  let resolve!: (diffs: GitDiff[]) => void;
  const promise = new Promise<GitDiff[]>((done) => {
    resolve = done;
  });
  releases.push(() => resolve([]));
  return { promise, resolve };
}
function start(hash = "A") {
  const task = preview({ kind: "commit", commit: commit(hash) }, "a.ts");
  inFlight.push(task);
  return task;
}

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  published = [];
  releases = [];
  inFlight = [];
  loadCommit = spyOn(api, "getCommitDiff").mockResolvedValue([diff(1)]);
  loadRange = spyOn(api, "getRefDiff").mockResolvedValue([diff(2)]);
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await render("A");
});
afterEach(async () => {
  try {
    await act(async () => {
      root?.unmount();
    });
    // Resolve every controlled request even when an assertion fails.
    for (const release of releases) release();
    await Promise.all(inFlight);
  } finally {
    loadCommit.mockRestore();
    loadRange.mockRestore();
    container.remove();
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

for (const reason of [
  "deselected",
  "hidden",
  "new-selection",
  "new-repository",
  "unmounted",
] as const) {
  test(`does not publish a pending preview after ${reason}`, async () => {
    const pending = pendingDiff();
    loadCommit.mockReturnValue(pending.promise);
    const task = start();
    if (reason === "unmounted") {
      await act(async () => {
        root!.unmount();
      });
      root = undefined;
    } else if (reason === "new-repository") {
      await render("A", "C:/other");
    } else {
      await render(reason === "new-selection" ? "B" : null);
    }
    pending.resolve([diff(1)]);
    await task;
    expect(published).toEqual([]);
  });
}

test("a later file click supersedes an earlier request and only opens once", async () => {
  const first = pendingDiff();
  const second = pendingDiff();
  loadCommit.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
  const older = start("A");
  const newer = start("B");
  second.resolve([diff(2)]);
  await newer;
  first.resolve([diff(1)]);
  await older;
  expect(published.map((data) => data.totalAdditions)).toEqual([2]);
});

test("disconnected commits retain every matching revision and its label", async () => {
  loadCommit
    .mockResolvedValueOnce([diff(3), diff(20, "other.ts")])
    .mockResolvedValueOnce([diff(7)]);
  await preview({ kind: "selection", commits: [commit("C"), commit("A")] }, "a.ts");
  expect(published).toHaveLength(1);
  expect(published[0].files.map((entry) => entry.additions)).toEqual([3, 20, 7]);
  expect(published[0].fileLabels).toEqual(["C", "C", "A"]);
  expect(published[0].fileRevisions).toEqual([
    { before: null, after: "C" }, { before: null, after: "C" }, { before: null, after: "A" },
  ]);
  expect(published[0].fileKeys).toEqual(["C:a.ts:0", "C:other.ts:1", "A:a.ts:0"]);
  expect(published[0].totalFiles).toBe(3);
  expect(published[0].initiallySelectedFileKey).toBe("C:a.ts:0");
  expect(published[0].commitFilePreview).toBe(true);
  expect(published[0].hideFileList).toBe(true);
});

test("contiguous selections still use the range diff and missing files do not open a tab", async () => {
  await preview(
    { kind: "range", baseRef: "A", targetRef: "C", oldest: commit("B"), newest: commit("C") },
    "a.ts",
  );
  expect(loadRange).toHaveBeenCalledWith("C:/repo", "A", "C");
  expect(published).toHaveLength(1);
  expect(published[0].totalAdditions).toBe(2);
  expect(published[0].fileRevisions).toEqual([{ before: "A", after: "C" }]);
  loadCommit.mockResolvedValue([]);
  await start();
  expect(published).toHaveLength(1);
});

test("single-commit titles use the first parent while root titles retain the empty tree", async () => {
  await preview({ kind: "commit", commit: { ...commit("merge"), parentHashes: ["first", "second"] } }, "a.ts");
  expect(published[0].fileRevisions).toEqual([{ before: "first", after: "merge" }]);
  await start("root");
  expect(published[1].fileRevisions).toEqual([{ before: null, after: "root" }]);
});
