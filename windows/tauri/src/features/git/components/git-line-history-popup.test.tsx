import { afterAll, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);

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
const openCommitDiffBuffer = mock(async (_options: unknown): Promise<string | null> => "buffer-1");

mock.module("@/core/lithe-core-client", () => ({ cancelCoreOperation }));
mock.module("@/features/git/api/git-line-history-api", () => ({ getGitLineHistory }));
mock.module("@/features/git/utils/open-commit-diff-buffer", () => ({ openCommitDiffBuffer }));

const { default: GitLineHistoryPopup } = await import("./git-line-history-popup");
const { createRoot } = await import("react-dom/client");

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
    expect(openCommitDiffBuffer).toHaveBeenCalledTimes(1);
    const options = openCommitDiffBuffer.mock.calls[0][0] as Record<string, unknown>;
    // Merge entries open against the recorded first-parent base, not a
    // combined merge diff, and land on the entry's relevant range.
    expect(options.compareReference).toBe(`${"d".repeat(40)}..${"c".repeat(40)}`);
    expect(options.pathspecs).toEqual(["doc.txt"]);
    expect(options.initialRevealRange).toEqual({ startLine: 3, endLine: 3 });

    await act(async () => {
      root.unmount();
      host.remove();
    });
  });
});
