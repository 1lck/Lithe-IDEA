import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as virtual from "@tanstack/react-virtual";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
import { GitCommitTable } from "./git-commit-table";

const commit = (hash: string, parents: string[] = []): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes: parents,
  message: hash,
  author: "Fixture",
  date: "unknown",
  decorations: "",
});
const commits = Array.from({ length: 40 }, (_, row) =>
  commit(String(row), row === 39 ? [] : row === 0 ? ["1", "39"] : [String(row + 1)]),
);
let restoreDom: () => void;
let root: Root;
let container: HTMLElement;
let previousPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
let previousActEnvironment: boolean | undefined;
let viewportSpy: ReturnType<typeof spyOn>;
let windowSize = 4;
let delayMount = false;
let releaseViewport: (() => void) | null = null;
let moveViewport: ((index: number) => void) | null = null;
const scrolled: number[] = [];
const selected = mock(
  (_commit: GitCommit, _visible: string[], _options: { additive: boolean; range: boolean }) => {},
);
const openDiff = mock((_commit: GitCommit) => {});
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

function Harness({
  values,
  navigationRequest = 0,
  repositoryCommits,
}: {
  values: GitCommit[];
  navigationRequest?: number;
  repositoryCommits?: GitCommit[];
}) {
  const [current, setCurrent] = useState<GitCommit | null>(null);
  const noop = () => {};
  return (
    <LocaleProvider language="en-US">
      <GitCommitTable
        commits={values}
        repositoryCommits={repositoryCommits}
        references={[]}
        selectedCommit={values.find((value) => value.hash === current?.hash) ?? null}
        selectedCommitHashes={new Set(current ? [current.hash] : [])}
        navigationRequest={navigationRequest}
        isMutatingHistory={false}
        hasMore={false}
        isLoadingMore={false}
        onSelect={(value, visible, options) => {
          selected(value, visible, options);
          setCurrent(value);
        }}
        onOpenDiff={openDiff}
        onContextSelect={noop}
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
    </LocaleProvider>
  );
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousPreferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({
    filterQuery: "",
    filterScope: "text",
    showLongGraphEdges: false,
  });
  scrolled.length = 0;
  windowSize = 4;
  delayMount = false;
  releaseViewport = null;
  moveViewport = null;
  selected.mockClear();
  openDiff.mockClear();
  // Control only the viewport. Scrolling mounts the destination just as the
  // real virtualizer does; matching, painting, selection and focus stay real.
  viewportSpy = spyOn(virtual, "useVirtualizer").mockImplementation(((
    options: Parameters<typeof virtual.useVirtualizer>[0],
  ) => {
    const [start, setStart] = useState(0);
    moveViewport = setStart;
    const viewport = useRef({});
    Object.assign(viewport.current, {
      getTotalSize: () => options.count * options.estimateSize(0),
      measure: () => {},
      getVirtualItems: () =>
        Array.from(
          { length: Math.max(0, Math.min(windowSize, options.count - start)) },
          (_, offset) => {
            const index = start + offset;
            const size = options.estimateSize(index);
            return {
              index,
              key: index,
              start: index * size,
              end: (index + 1) * size,
              size,
              lane: 0,
            };
          },
        ),
      scrollToIndex: (index: number) => {
        scrolled.push(index);
        const reveal = () => setStart(Math.max(0, Math.min(index - 1, options.count - windowSize)));
        if (delayMount) releaseViewport = reveal;
        else reveal();
      },
    });
    return viewport.current;
  }) as unknown as typeof virtual.useVirtualizer);
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  releaseViewport = null;
  moveViewport = null;
  viewportSpy.mockRestore();
  useGitLogPreferencesStore.setState(previousPreferences, true);
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

const mount = async (values = commits) => {
  await act(async () => root.render(<Harness values={values} />));
};
const click = async (element: Element) => {
  await act(async () => element.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
};
test("long-edge arrows select, reveal and focus offscreen parent and child without selecting the source row", async () => {
  await mount();
  expect(container.querySelector('[data-git-commit-hash="39"]')).toBeNull();
  const down = container.querySelector('[data-git-graph-target="39"]')!;
  expect(down.getAttribute("aria-label")).toBe("Go to parent commit 39");
  await click(down);
  expect(selected).toHaveBeenCalledTimes(1);
  expect(selected.mock.calls[0][0].hash).toBe("39");
  expect(selected.mock.calls[0][2]).toEqual({ additive: false, range: false });
  expect(scrolled).toContain(39);
  expect(document.activeElement?.getAttribute("data-git-commit-hash")).toBe("39");
  expect(container.querySelector('[data-git-commit-hash="39"]')?.getAttribute("aria-pressed")).toBe(
    "true",
  );
  const up = container.querySelector('[data-git-graph-target="0"]')!;
  expect(up.getAttribute("aria-label")).toBe("Go to child commit 0");
  await click(up);
  expect(selected.mock.calls.map(([value]) => value.hash)).toEqual(["39", "0"]);
  expect(document.activeElement?.getAttribute("data-git-commit-hash")).toBe("0");
  expect(openDiff).not.toHaveBeenCalled();
});

test("focus waits for an explicitly delayed virtual-row mount and survives reference-only repainting", async () => {
  delayMount = true;
  await mount();
  await click(container.querySelector('[data-git-graph-target="39"]')!);
  expect(selected.mock.calls[0][0].hash).toBe("39");
  expect(container.querySelector('[data-git-commit-hash="39"]')).toBeNull();
  expect(document.activeElement?.getAttribute("data-git-commit-hash")).not.toBe("39");
  expect(releaseViewport).not.toBeNull();
  await act(async () => releaseViewport?.());
  expect(document.activeElement?.getAttribute("data-git-commit-hash")).toBe("39");
});

test("the real toolbar expands and collapses long edges without changing selection", async () => {
  windowSize = 40;
  await mount();
  const pathsInMiddle = () =>
    container.querySelector('[data-git-commit-hash="20"]')!.querySelectorAll("svg path").length;
  expect(pathsInMiddle()).toBe(2);
  await click(container.querySelector('button[aria-label="Show long graph edges"]')!);
  expect(pathsInMiddle()).toBe(4);
  expect(
    container
      .querySelector('button[aria-label="Collapse long graph edges"]')
      ?.getAttribute("aria-pressed"),
  ).toBe("true");
  expect(useGitLogPreferencesStore.getState().showLongGraphEdges).toBe(true);
  await click(container.querySelector('button[aria-label="Collapse long graph edges"]')!);
  expect(pathsInMiddle()).toBe(2);
  expect(selected).not.toHaveBeenCalled();
});

test("arrow key activation does not trigger the source row's Enter diff action and unmount releases DOM focus", async () => {
  await mount();
  const arrow = container.querySelector('[data-git-graph-target="39"]')!;
  await act(async () =>
    arrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
  );
  expect(openDiff).not.toHaveBeenCalled();
  // Happy DOM does not synthesize the browser's native Enter -> click. Drive
  // that activation boundary explicitly; Chromium covers the native sequence.
  await click(arrow);
  expect(document.activeElement?.getAttribute("data-git-commit-hash")).toBe("39");
  await act(async () => root.unmount());
  expect(document.activeElement).toBe(document.body);
});

test("missing-history markers have no navigation target and ordinary row selection and diff remain available", async () => {
  await mount([commit("tip", ["missing"]), commit("other")]);
  expect(container.querySelectorAll("[data-git-graph-target]")).toHaveLength(0);
  const row = container.querySelector('[data-git-commit-hash="tip"]')!;
  await click(row);
  await act(async () => row.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true })));
  expect(selected.mock.calls[0][0].hash).toBe("tip");
  expect(openDiff.mock.calls[0][0].hash).toBe("tip");
  await act(async () => useGitLogPreferencesStore.getState().actions.setFilterQuery("no-match"));
  expect(container.querySelectorAll("[data-git-graph-target]")).toHaveLength(0);
});

test("appending a page and repainting references preserve the manually scrolled viewport and selection", async () => {
  await mount();
  await click(container.querySelector('[data-git-commit-hash="0"]')!);
  await act(async () => moveViewport?.(36));
  scrolled.length = 0;
  expect(container.querySelector('[data-git-commit-hash="0"]')).toBeNull();
  const nextPage = Array.from({ length: 40 }, (_, index) => commit(String(index + 40)));
  await mount([...commits, ...nextPage]);
  await act(async () =>
    root.render(
      <Harness
        values={[{ ...commits[0], message: "Updated metadata" }, ...commits.slice(1), ...nextPage]}
        repositoryCommits={[...commits, ...nextPage]}
      />,
    ),
  );
  expect(scrolled).toEqual([]);
  expect(container.querySelector('[data-git-commit-hash="36"]')).not.toBeNull();
  expect(container.querySelector('[data-git-commit-hash="0"]')).toBeNull();
  expect(selected.mock.calls.map(([value]) => value.hash)).toEqual(["0"]);
});

test("an explicit branch-head reveal still scrolls when its commit is already selected, once per request", async () => {
  await mount();
  await click(container.querySelector('[data-git-commit-hash="0"]')!);
  await act(async () => moveViewport?.(36));
  scrolled.length = 0;
  await act(async () => root.render(<Harness values={commits} navigationRequest={1} />));
  expect(scrolled).toEqual([0]);
  expect(container.querySelector('[data-git-commit-hash="0"]')).not.toBeNull();
  await act(async () => root.render(<Harness values={[...commits]} navigationRequest={1} />));
  expect(scrolled).toEqual([0]);
  expect(selected).toHaveBeenCalledTimes(1);
});
