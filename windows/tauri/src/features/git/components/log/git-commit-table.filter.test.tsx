import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as virtual from "@tanstack/react-virtual";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
import { GitCommitTable } from "./git-commit-table";

let restoreDom: () => void;
let container: HTMLElement;
let root: Root;
let viewportSpy: ReturnType<typeof spyOn>;
let previousPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousPreferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({ filterQuery: "keep", filterScope: "text" });
  // Control the viewport only. The real table computes matches and graph rows.
  const viewport = ((options: Parameters<typeof virtual.useVirtualizer>[0]) => ({
    getTotalSize: () => options.count * options.estimateSize(0),
    getVirtualItems: () =>
      Array.from({ length: options.count }, (_, index) => ({
        index,
        key: index,
        start: index * options.estimateSize(index),
        size: options.estimateSize(index),
        end: (index + 1) * options.estimateSize(index),
        lane: 0,
      })),
    scrollToIndex: () => {},
    measure: () => {},
  })) as unknown as typeof virtual.useVirtualizer;
  viewportSpy = spyOn(virtual, "useVirtualizer").mockImplementation(viewport);
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  viewportSpy.mockRestore();
  useGitLogPreferencesStore.setState(previousPreferences, true);
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

for (const scope of ["text", "author", "branch"] as const) {
  test(`the actual table projects ${scope} matches and restores direct edges when clearing the query`, async () => {
    useGitLogPreferencesStore.setState({ filterScope: scope });
    const commits: GitCommit[] = ["a", "b", "c"].map((hash, row) => ({
      hash,
      shortHash: hash,
      parentHashes: row < 2 ? [String.fromCharCode(hash.charCodeAt(0) + 1)] : [],
      message: row === 1 ? "hidden" : "keep",
      author: row === 1 ? "hidden" : "keep",
      date: "unknown",
      decorations: row === 1 ? "" : `keep-${hash}`,
    }));
    const noop = () => {};
    await act(async () => {
      root.render(
        <LocaleProvider language="en-US">
          <GitCommitTable
            commits={commits}
            selectedCommit={null}
            selectedCommitHashes={new Set()}
            isMutatingHistory={false}
            hasMore={false}
            isLoadingMore={false}
            onSelect={noop}
            onContextSelect={noop}
            onOpenDiff={noop}
            onCompareWithHead={noop}
            onCopyHash={noop}
            onCopyShortHash={noop}
            onCopyMessage={noop}
            onEditMessage={noop}
            onUndo={noop}
            onInteractiveRebase={noop}
            onExportPatch={noop}
            onDelete={noop}
            onSquash={noop}
            onReset={noop}
            onCherryPick={noop}
            onRevert={noop}
            onCreateTag={noop}
            onLoadMore={noop}
          />
        </LocaleProvider>,
      );
    });
    expect(container.querySelectorAll("[data-git-commit-index]")).toHaveLength(2);
    expect(container.querySelectorAll("svg path[stroke-dasharray]")).toHaveLength(2);
    await act(async () => useGitLogPreferencesStore.getState().actions.setFilterQuery(""));
    expect(container.querySelectorAll("[data-git-commit-index]")).toHaveLength(3);
    expect(container.querySelectorAll("svg path[stroke-dasharray]")).toHaveLength(0);
    await act(async () =>
      useGitLogPreferencesStore.getState().actions.setFilterQuery("no-matching-commit"),
    );
    expect(container.querySelectorAll("[data-git-commit-index]")).toHaveLength(0);
    expect(container.querySelectorAll("svg path[stroke-dasharray]")).toHaveLength(0);
  });
}
