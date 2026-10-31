import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as commitsApi from "../../api/git-commits-api";
import * as diffApi from "../../api/git-diff-api";
import type { GitCommit, GitCommitFile, GitDiff } from "../../types/git.types";
import { moveCommitFile } from "../../utils/commit-file-diff-navigation";
import { COMMIT_FILE_PREVIEW_PATH, createCommitFileDiffPreview } from "../../utils/multi-file-diff";
import { GitCommitInspector } from "./git-commit-inspector";

const commit = (hash: string, parents: string[] = []): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes: parents,
  message: hash,
  author: "Fixture",
  date: "unknown",
  decorations: "",
  description: "",
});
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let restoreDom: () => void;
let root: Root;
let container: HTMLElement;
let filesSpy: ReturnType<typeof spyOn>;
let rangeSpy: ReturnType<typeof spyOn>;
const requests: Array<{
  repo: string;
  hash: string;
  resolve: (files: GitCommitFile[] | null) => void;
}> = [];
const preview = mock(() => {});
const noop = () => {};
const previousGlobals = new Map<string, PropertyDescriptor | undefined>();

beforeEach(() => {
  restoreDom = installHappyDom();
  for (const key of ["DOMRect", "ResizeObserver"] as const) {
    previousGlobals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, {
      configurable: true,
      writable: true,
      value: window[key],
    });
  }
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  requests.length = 0;
  preview.mockClear();
  filesSpy = spyOn(commitsApi, "getCommitFiles").mockImplementation(
    (repo, hash) => new Promise((resolve) => requests.push({ repo, hash, resolve })),
  );
  rangeSpy = spyOn(diffApi, "getRefDiff").mockResolvedValue([]);
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
    for (const request of requests) request.resolve(null);
  });
  filesSpy.mockRestore();
  rangeSpy.mockRestore();
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  for (const [key, descriptor] of previousGlobals) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
  previousGlobals.clear();
  restoreDom();
});

const render = async (values: GitCommit[], repoPath = "C:/fixture", previewRequest = 0) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCommitInspector
          repoPath={repoPath}
          commit={values[0] ?? null}
          commits={values}
          previewRequest={previewRequest}
          onPreviewFile={preview}
          onOpenDiff={noop}
          onOpenRangeDiff={noop}
          onOpenSelectionDiff={noop}
        />
      </LocaleProvider>,
    ),
  );
};
const release = async (index: number, path: string) => {
  await act(async () => requests[index].resolve([{ path, status: "M" }]));
};

test("pagination selection arrays and metadata repainting retain loaded files without another read", async () => {
  const selected = commit("tip");
  await render([selected]);
  await release(0, "kept.ts");
  const findFileRow = () =>
    [...container.querySelectorAll("[data-sidebar-tree-row]")].find((row) =>
      row.textContent?.includes("kept.ts"),
    );
  const fileRow = findFileRow();
  expect(fileRow).toBeDefined();
  await act(async () => fileRow!.querySelector<HTMLButtonElement>('[role="treeitem"]')!.click());
  expect(fileRow).not.toBeNull();
  await render([selected]);
  await render([{ ...selected, message: "Updated metadata" }]);
  expect(filesSpy).toHaveBeenCalledTimes(1);
  expect(findFileRow()).toBe(fileRow);
  expect(findFileRow()?.getAttribute("data-active")).toBe("true");
  expect(container.textContent).toContain("Updated metadata");
  expect(preview).toHaveBeenCalledTimes(1);
});

test("repainting a pending selection keeps its original request and explicit preview runs after loading", async () => {
  await render([commit("tip")]);
  await render([commit("tip")], "C:/fixture", 1);
  expect(filesSpy).toHaveBeenCalledTimes(1);
  await release(0, "preview.ts");
  expect(container.textContent).toContain("preview.ts");
  expect(preview).toHaveBeenCalledTimes(1);
  await render([commit("tip")], "C:/fixture", 1);
  expect(preview).toHaveBeenCalledTimes(1);
});

test("unchanged contiguous and discontiguous selections do not reload range or aggregate files", async () => {
  await render([commit("new", ["old"]), commit("old", ["base"])]);
  await render([commit("new", ["old"]), commit("old", ["base"])]);
  expect(rangeSpy).toHaveBeenCalledTimes(1);
  await render([commit("a"), commit("b")]);
  await act(async () => {
    for (const request of requests) request.resolve([]);
  });
  await render([commit("a"), commit("b")]);
  expect(filesSpy).toHaveBeenCalledTimes(2);
});

test("a new commit or repository loads files and ignores late answers from the old owner", async () => {
  await render([commit("a")]);
  await render([commit("b")]);
  await release(0, "stale.ts");
  expect(container.textContent).not.toContain("stale.ts");
  await release(1, "current.ts");
  expect(container.textContent).toContain("current.ts");
  await render([commit("b")], "C:/other", 1);
  expect(filesSpy).toHaveBeenCalledTimes(3);
  expect(preview).not.toHaveBeenCalled();
  await release(2, "other.ts");
  expect(container.textContent).toContain("other.ts");
  expect(preview).toHaveBeenCalledTimes(1);
});

const fail = async (index: number) => {
  await act(async () => requests[index].resolve(null));
};
const clickRetry = async () => {
  const retry = [...container.querySelectorAll("button")].find(
    (button) => button.textContent === "Retry",
  );
  expect(retry).toBeDefined();
  await act(async () => retry!.click());
};

test("a failed read retries when the user selects the same commit again and then stays stable", async () => {
  await render([commit("tip")]);
  await fail(0);
  expect(container.textContent).toContain("Unable to load changed files");
  expect(preview).not.toHaveBeenCalled();

  // Only explicit selections bump previewRequest; the retry must also preview once it succeeds.
  await render([commit("tip")], "C:/fixture", 1);
  expect(filesSpy).toHaveBeenCalledTimes(2);
  await release(1, "recovered.ts");
  expect(container.textContent).toContain("recovered.ts");
  expect(container.textContent).not.toContain("Unable to load changed files");
  expect(preview).toHaveBeenCalledTimes(1);

  await render([commit("tip")], "C:/fixture", 1);
  await render([{ ...commit("tip"), message: "Updated metadata" }], "C:/fixture", 1);
  expect(filesSpy).toHaveBeenCalledTimes(2);
});

test("a failed read retries when history refresh delivers a new object for the same commit", async () => {
  await render([commit("tip")]);
  await fail(0);
  await render([{ ...commit("tip"), message: "Refreshed" }]);
  expect(filesSpy).toHaveBeenCalledTimes(2);
  await release(1, "refreshed.ts");
  expect(container.textContent).toContain("refreshed.ts");
});

test("the retry action reloads a failed selection without needing a new selection", async () => {
  await render([commit("tip")]);
  await fail(0);
  await clickRetry();
  expect(filesSpy).toHaveBeenCalledTimes(2);
  expect(container.textContent).toContain("Loading changed files");
  await release(1, "manual.ts");
  expect(container.textContent).toContain("manual.ts");
});

test("a failure on the previous commit does not double-load the newly selected commit", async () => {
  await render([commit("a")]);
  await fail(0);
  await render([commit("b")], "C:/fixture", 1);
  expect(filesSpy).toHaveBeenCalledTimes(2);
  await release(1, "b.ts");
  expect(container.textContent).toContain("b.ts");
  expect(filesSpy).toHaveBeenCalledTimes(2);
});

test("a pending read is not restarted by repainting, only failures retry", async () => {
  await render([commit("tip")]);
  await render([{ ...commit("tip"), message: "Repainted" }], "C:/fixture", 1);
  expect(filesSpy).toHaveBeenCalledTimes(1);
});

test("the file list selection follows the preview when it moves to another file", async () => {
  const diff = (path: string): GitDiff => ({
    file_path: path,
    is_new: false,
    is_deleted: false,
    is_renamed: false,
    lines: [],
    additions: 1,
    deletions: 0,
  });
  const showPreview = async (
    data: NonNullable<ReturnType<typeof createCommitFileDiffPreview>>["diffData"],
  ) =>
    act(async () =>
      useBufferStore.setState({
        activeBufferId: COMMIT_FILE_PREVIEW_PATH,
        buffers: [
          createPaneContent(COMMIT_FILE_PREVIEW_PATH, {
            type: "diff",
            path: COMMIT_FILE_PREVIEW_PATH,
            name: "preview",
            content: "",
            diffData: data,
          }),
        ],
      }),
    );
  const selectedRows = () =>
    [...container.querySelectorAll('[data-sidebar-tree-row][data-active="true"]')].map(
      (row) => row.textContent,
    );
  const fixture = (hash: string) =>
    createCommitFileDiffPreview({
      repoPath: "C:/fixture",
      commitHash: hash,
      diffs: [diff("a.ts"), diff("b.ts")],
      filePath: "a.ts",
      label: hash,
    })!.diffData;

  await render([commit("tip")]);
  await act(async () =>
    requests[0].resolve([
      { path: "a.ts", status: "M" },
      { path: "b.ts", status: "M" },
    ]),
  );
  const first = fixture("tip");
  await showPreview(first);
  expect(selectedRows().map((text) => text?.includes("a.ts"))).toEqual([true]);

  // The diff toolbar's next-file action replaces the buffer data without touching the tree.
  await showPreview(moveCommitFile(first, 1)!);
  expect(selectedRows().map((text) => text?.includes("b.ts"))).toEqual([true]);

  // A preview that belongs to another commit must not move this selection.
  await showPreview(fixture("other"));
  expect(selectedRows().map((text) => text?.includes("b.ts"))).toEqual([true]);
  useBufferStore.setState({ activeBufferId: null, buffers: [] });
});

test("following the preview reopens a folder the user had collapsed", async () => {
  const diff = (path: string): GitDiff => ({
    file_path: path,
    is_new: false,
    is_deleted: false,
    is_renamed: false,
    lines: [],
    additions: 1,
    deletions: 0,
  });
  const data = createCommitFileDiffPreview({
    repoPath: "C:/fixture",
    commitHash: "tip",
    diffs: [diff("a/x.ts"), diff("b/y.ts")],
    filePath: "a/x.ts",
    label: "tip",
  })!.diffData;
  const show = async (diffData: typeof data) =>
    act(async () =>
      useBufferStore.setState({
        activeBufferId: COMMIT_FILE_PREVIEW_PATH,
        buffers: [
          createPaneContent(COMMIT_FILE_PREVIEW_PATH, {
            type: "diff",
            path: COMMIT_FILE_PREVIEW_PATH,
            name: "preview",
            content: "",
            diffData,
          }),
        ],
      }),
    );
  const rows = () => [...container.querySelectorAll("[data-sidebar-tree-row]")];
  const rowText = (name: string) =>
    rows().find((row) => row.textContent?.includes(name)) as HTMLElement | undefined;

  await render([commit("tip")]);
  await act(async () =>
    requests[0].resolve([
      { path: "a/x.ts", status: "M" },
      { path: "b/y.ts", status: "M" },
    ]),
  );
  await show(data);
  await act(async () =>
    rowText("b1 file")!.querySelector<HTMLElement>('[role="treeitem"]')!.click(),
  );
  expect(rowText("y.ts")).toBeUndefined();

  await show(moveCommitFile(data, 1)!);
  expect(rowText("y.ts")?.getAttribute("data-active")).toBe("true");
  useBufferStore.setState({ activeBufferId: null, buffers: [] });
});
