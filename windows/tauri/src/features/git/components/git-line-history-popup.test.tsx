import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);

// All commands the sibling line-history suites may route through this shared
// mock: bun's mock.module registry is global across test files, so whichever
// file registers last must still serve every consumer.
const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.lineHistory") {
    return { baseCommit: "b".repeat(40), unmappedLines: [], commits: [], truncated: false };
  }
  if (command === "git.diff") {
    return [{ file_path: "doc.txt", new_path: "doc.txt", lines: [] }];
  }
  if (command === "git_commit_diff") {
    return [{ file_path: "doc.txt", new_path: "doc.txt", lines: [] }];
  }
  throw new Error(`Unexpected command: ${command}`);
});

const cancelCoreOperation = mock(async () => true);
let resolveQuery: ((value: unknown) => void) | null = null;
interface MockedLineHistoryQuery {
  operationId: string;
  startLine: number;
  endLine: number;
}
const getGitLineHistory = mock((_query: MockedLineHistoryQuery) =>
  new Promise<unknown>((resolve) => {
    resolveQuery = resolve;
  }),
);
const openBuffer = mock(
  async (
    _virtualPath: string,
    _displayName: string,
    _content: string,
    _preview: boolean,
    _undefined: undefined,
    _pinned: boolean,
    _restored: boolean,
    diffData: Record<string, unknown>,
  ) => "buffer-1",
);

const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));
mock.module("@/core/lithe-core-client", () => ({ cancelCoreOperation }));
mock.module("@/features/git/api/git-line-history-api", () => ({ getGitLineHistory }));
const bufferStoreModule = await import("@/features/editor/stores/buffer.store");
mock.module("@/features/editor/stores/buffer.store", () => ({
  ...bufferStoreModule,
  useBufferStore: { getState: () => ({ actions: { openBuffer } }) },
}));

const { default: GitLineHistoryPopup } = await import("./git-line-history-popup");
const { createRoot } = await import("react-dom/client");
const { clearRepositoryDiscoveryCache } = await import("@/features/git/api/git-repo-api");

beforeEach(() => {
  invoke.mockClear();
  openBuffer.mockClear();
  // Discovery caching would leak one test's repository identity into the
  // next entry-open assertion.
  clearRepositoryDiscoveryCache();
});

const sampleHistory = {
  baseCommit: "b".repeat(40),
  unmappedLines: [{ line: 4, kind: "unreliable" as const }],
  commits: [
    {
      hash: "c".repeat(40),
      kind: "merge-first-parent" as const,
      authorName: "Tester",
      authorTime: 1792100000,
      subject: "merge side",
      pathAtCommit: "doc.txt",
      previousPath: null,
      compareBase: "d".repeat(40),
      relevantRanges: [{ oldStart: 3, oldEnd: 3, newStart: 3, newEnd: 3 }],
    },
  ],
  truncated: true,
};

function mountPopup() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  const close = mock(() => {});
  act(() => {
    root.render(
      <LocaleProvider>
        <GitLineHistoryPopup
          rootPath="C:/repo"
          filePath="doc.txt"
          content="one\ntwo\n"
          range={{ startLine: 2, endLine: 2 }}
          anchor={{ x: 40, y: 40 }}
          onClose={close}
        />
      </LocaleProvider>,
    );
  });
  return { host, root, close };
}

async function flush() {
  // Drain microtasks only: the popup's promise chain never waits on timers.
  await act(async () => {
    await Promise.resolve();
  });
}

describe("GitLineHistoryPopup", () => {
  test("cancels the pending operation on close and drops the late result", async () => {
    const { host, root } = mountPopup();
    await flush();
    expect(getGitLineHistory).toHaveBeenCalledTimes(1);
    const operationId = getGitLineHistory.mock.calls[0][0].operationId;
    expect(operationId).toBeTruthy();

    // Closing unmounts the popup; the still-pending query must be cancelled.
    let pendingResolve = resolveQuery;
    expect(pendingResolve).toBeTruthy();
    await act(async () => {
      root.unmount();
      host.remove();
    });
    expect(cancelCoreOperation).toHaveBeenCalledWith(operationId);

    // The late result must not resurrect state on the unmounted popup.
    resolveQuery = null;
    (pendingResolve as (value: unknown) => void)({
      history: sampleHistory,
      repoPath: "C:/repo",
      filePath: "doc.txt",
    });
    await flush();
    expect(document.querySelector("[data-line-history-entry]")).toBeNull();
  });

  test("renders unmapped notices, merge entries, and the truncation note", async () => {
    const { host, root } = mountPopup();
    await flush();
    await act(async () => {
      resolveQuery?.({
        history: sampleHistory,
        repoPath: "C:/repo",
        filePath: "doc.txt",
      });
    });
    await flush();

    expect(host.querySelector("[data-line-history-unmapped='unreliable']")).toBeTruthy();
    const entry = host.querySelector<HTMLButtonElement>("[data-line-history-entry]");
    expect(entry).toBeTruthy();
    expect(host.querySelector("[data-line-history-merge]")).toBeTruthy();
    expect(host.querySelector("[data-line-history-truncated]")).toBeTruthy();

    entry!.click();
    await flush();
    // The click traverses the real scoped-open path: the dotted git.diff
    // carries the merge's first-parent comparison, and the opened buffer is
    // the single-file preview carrying the reveal range.
    const scoped = invoke.mock.calls.find((call) => call[0] === "git.diff");
    expect(scoped).toBeTruthy();
    const args = scoped?.[1] as Record<string, unknown>;
    expect(args.reference).toBe(`${"d".repeat(40)}..${"c".repeat(40)}`);
    expect(args.pathspecs).toEqual(["doc.txt"]);
    expect(openBuffer).toHaveBeenCalledTimes(1);
    const diffData = openBuffer.mock.calls[0][7] as Record<string, unknown>;
    expect(diffData.commitFilePreview).toBe(true);
    expect(diffData.initialRevealRange).toEqual({ startLine: 3, endLine: 3 });

    await act(async () => {
      root.unmount();
      host.remove();
    });
  });

  test("rename-with-edit entries open the single-file preview with positioning", async () => {
    const { host, root } = mountPopup();
    await flush();
    const renamedEntry = {
      ...sampleHistory.commits[0],
      kind: "commit" as const,
      pathAtCommit: "renamed.txt",
      previousPath: "original.txt",
    };
    await act(async () => {
      resolveQuery?.({
        history: { ...sampleHistory, commits: [renamedEntry] },
        repoPath: "C:/repo",
        filePath: "doc.txt",
      });
    });
    await flush();

    const entry = host.querySelector<HTMLButtonElement>("[data-line-history-entry]");
    // The scoped diff answers with the renamed file so the preview can pick
    // its target; stacked one-shot mocks cover the discovery then the diff.
    invoke.mockImplementationOnce(async () => "C:/repo");
    invoke.mockImplementationOnce(async () => [
      { file_path: "renamed.txt", new_path: "renamed.txt", lines: [] },
    ]);
    entry!.click();
    await flush();
    const scoped = invoke.mock.calls.find((call) => call[0] === "git.diff");
    expect(scoped).toBeTruthy();
    const args = scoped?.[1] as Record<string, unknown>;
    // Both rename sides ride the request so git keeps the pairing, and the
    // current path lands the preview.
    expect(args.pathspecs).toEqual(["original.txt", "renamed.txt"]);
    expect(openBuffer).toHaveBeenCalledTimes(1);
    const diffData = openBuffer.mock.calls[0][7] as Record<string, unknown>;
    expect(diffData.commitFilePreview).toBe(true);
    expect(diffData.initialRevealRange).toEqual({ startLine: 3, endLine: 3 });

    await act(async () => {
      root.unmount();
      host.remove();
    });
  });

  test("offers a whole-commit entry that opens the unscoped stack", async () => {
    const { host, root } = mountPopup();
    await flush();
    await act(async () => {
      resolveQuery?.({
        history: sampleHistory,
        repoPath: "C:/nested/repo",
        filePath: "doc.txt",
      });
    });
    await flush();

    const whole = host.querySelector<HTMLButtonElement>("[data-line-history-whole-commit]");
    expect(whole).toBeTruthy();
    whole!.click();
    await flush();
    const discover = invoke.mock.calls.find((call) => call[0] === "git_discover_repo");
    const discoverArgs = discover?.[1] as Record<string, unknown> | undefined;
    // The whole-commit entry resolves through the repository the query
    // reported, not the workspace root, and keeps the generic stack.
    expect(String(discoverArgs?.path ?? "")).toContain("C:/nested/repo");
    const wholeDiff = openBuffer.mock.calls[0][7] as Record<string, unknown>;
    expect(wholeDiff.commitFilePreview).toBeUndefined();

    await act(async () => {
      root.unmount();
      host.remove();
    });
  });
});
