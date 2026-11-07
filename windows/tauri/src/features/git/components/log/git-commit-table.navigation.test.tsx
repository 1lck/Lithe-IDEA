import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, useCallback, useMemo, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as virtual from "@tanstack/react-virtual";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { installGitGraphProjectionStub } from "@/test-utils/git-graph-projection-stub";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
import { GitCommitTable, GRAPH_LOCATE_PAGE_BUDGET } from "./git-commit-table";

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
  hasMore = false,
  isLoadingMore = false,
  onLoadMore,
}: {
  values: GitCommit[];
  navigationRequest?: number;
  repositoryCommits?: GitCommit[];
  hasMore?: boolean;
  isLoadingMore?: boolean;
  onLoadMore?: () => Promise<boolean> | boolean | void;
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
        hasMore={hasMore}
        isLoadingMore={isLoadingMore}
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
        onLoadMore={onLoadMore ?? noop}
        onSelectReference={noop}
      />
    </LocaleProvider>
  );
}

let graphStub: ReturnType<typeof installGitGraphProjectionStub>;

beforeEach(() => {
  restoreDom = installHappyDom();
  graphStub = installGitGraphProjectionStub();
  // Paging tests mount with `hasMore`; the sentinel observer is not under test.
  const globe = globalThis as typeof globalThis & { IntersectionObserver?: unknown };
  globe.IntersectionObserver ??= class {
    root = null;
    rootMargin = "";
    scrollMargin = "";
    thresholds = [];
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  };
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
  graphStub.mockRestore();
  restoreDom();
});

const mount = async (values = commits) => {
  await act(async () => root.render(<Harness values={values} />));
};
const mountWith = async (
  values: GitCommit[],
  options: {
    hasMore?: boolean;
    isLoadingMore?: boolean;
    onLoadMore?: () => Promise<boolean> | boolean | void;
  } = {},
) => {
  await act(async () =>
    root.render(
      <Harness
        values={values}
        hasMore={options.hasMore}
        isLoadingMore={options.isLoadingMore}
        onLoadMore={options.onLoadMore}
      />,
    ),
  );
};

/**
 * Drives pagination through component state so page arrivals rerender inside
 * the normal React flow — no nested `act` left pending after an assertion.
 */
function PagedHarness({
  pages,
  onLoadObserved,
}: {
  pages: GitCommit[][];
  onLoadObserved?: () => void;
}) {
  const [pageIndex, setPageIndex] = useState(1);
  const [current, setCurrent] = useState<GitCommit | null>(null);
  const values = useMemo(() => pages.slice(0, pageIndex).flat(), [pages, pageIndex]);
  const hasMore = pageIndex < pages.length;
  const noop = () => {};
  const loadMore = useCallback(async () => {
    onLoadObserved?.();
    if (pageIndex >= pages.length) return false;
    setPageIndex((index) => index + 1);
    return true;
  }, [onLoadObserved, pageIndex, pages.length]);
  return (
    <LocaleProvider language="en-US">
      <GitCommitTable
        commits={values}
        references={[]}
        selectedCommit={values.find((value) => value.hash === current?.hash) ?? null}
        selectedCommitHashes={new Set(current ? [current.hash] : [])}
        isMutatingHistory={false}
        hasMore={hasMore}
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
        onLoadMore={loadMore}
        onSelectReference={noop}
      />
    </LocaleProvider>
  );
}
const mountPaged = async (pages: GitCommit[][], onLoadObserved?: () => void) => {
  await act(async () => root.render(<PagedHarness pages={pages} onLoadObserved={onLoadObserved} />));
};
/** Core owns layout: paging tests replay Core-shaped missing-parent edges, not TS routing. */
const useMissingParentProjection = () => {
  graphStub.mockRestore();
  graphStub = installGitGraphProjectionStub({ missingParents: true });
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
  // The shared canvas paints both adjacent edges through row 20's center.
  // Expanding the long edge adds its incoming and outgoing paths there.
  const pathsInMiddle = () =>
    [...container.querySelectorAll("[data-git-graph-edges] > path")].filter((path) =>
      /[ML] [-\d.]+ 533(?: |$)/.test(path.getAttribute("d") ?? ""),
    ).length;
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

test("missing-history markers offer a locate target while ordinary selection and diff remain available", async () => {
  useMissingParentProjection();
  const loadMore = mock(async () => false);
  await mountWith([commit("tip", ["missing"]), commit("other")], { onLoadMore: loadMore });
  const locate = container.querySelector('[data-git-graph-target="missing"]')!;
  expect(locate.getAttribute("aria-label")).toBe("Locate parent commit missing");
  // History is exhausted: the click resolves with feedback, never more paging.
  await click(locate);
  expect(loadMore).not.toHaveBeenCalled();
  const row = container.querySelector('[data-git-commit-hash="tip"]')!;
  await click(row);
  await act(async () => row.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true })));
  expect(selected.mock.calls[0][0].hash).toBe("tip");
  expect(openDiff.mock.calls[0][0].hash).toBe("tip");
  await act(async () => useGitLogPreferencesStore.getState().actions.setFilterQuery("no-match"));
  expect(container.querySelectorAll("[data-git-graph-target]")).toHaveLength(0);
});

test("a fresh batch of missing parents preloads within the bounded page budget", async () => {
  useMissingParentProjection();
  // Page 1 ends at "tip" whose parent "missing" only arrives with page 3.
  const page1 = [
    commit("tip", ["missing"]),
    // The filler chain closes on itself: "tip"'s parent is the only missing one.
    ...Array.from({ length: 9 }, (_, index) =>
      commit(`row${index}`, index === 8 ? [] : [`row${index + 1}`]),
    ),
  ];
  // Each filler page's chain closes on itself: no new missing parents of its own.
  const page2 = [
    ...Array.from({ length: 9 }, (_, index) => commit(`far${index}`, [`far${index + 1}`])),
    commit("far9"),
  ];
  const page3 = [commit("missing", ["root"]), commit("root")];
  let loads = 0;
  await mountPaged([page1, page2, page3], () => {
    loads += 1;
  });
  // The preload chained pages 2 and 3 on its own; every parent became jumpable.
  expect(loads).toBe(2);
  expect(container.querySelector('[data-git-graph-target="missing"]')).toBeNull();
  const row = container.querySelector('[data-git-commit-hash="tip"]')!;
  await click(row);
  expect(selected).toHaveBeenCalledTimes(1);
});

test("the preload budget stops after five pages even when parents stay missing", async () => {
  useMissingParentProjection();
  // The second row carries the missing-parent arrow; every later page is filler
  // that never contains the parent, so the budget alone stops the chain.
  const page1 = [commit("tip", ["missing"]), commit("other")];
  const fillerPage = (index: number) => [commit(`fill${index}`)];
  let loads = 0;
  await mountPaged(
    Array.from({ length: 12 }, (_, index) => (index === 0 ? page1 : fillerPage(index))),
    () => {
      loads += 1;
    },
  );
  expect(loads).toBe(GRAPH_LOCATE_PAGE_BUDGET);
  // The filter suppresses preloading entirely for newly arriving pages.
  await act(async () => useGitLogPreferencesStore.getState().actions.setFilterQuery("tip"));
  loads = 0;
  await act(async () =>
    root.render(
      <PagedHarness
        pages={Array.from({ length: 12 }, (_, index) => (index === 0 ? page1 : fillerPage(index)))}
        onLoadObserved={() => {
          loads += 1;
        }}
      />,
    ),
  );
  expect(loads).toBe(0);
});

test("clicking a missing-parent arrow locates the target through bounded pages and reveals it", async () => {
  useMissingParentProjection();
  // The second row carries the missing-parent arrow; the preload budget burns
  // filler pages first, and the click's own locate run reaches the parent page.
  const page1 = [commit("tip", ["missing"]), commit("other")];
  const fillerPage = (index: number) => [commit(`fill${index}`)];
  const targetPage = [commit("missing", ["root"]), commit("root")];
  let loads = 0;
  const pages = [
    page1,
    ...Array.from({ length: GRAPH_LOCATE_PAGE_BUDGET }, (_, index) => fillerPage(index + 1)),
    targetPage,
  ];
  await mountPaged(pages, () => {
    loads += 1;
  });
  // The fresh missing batch preloaded its full budget without reaching the parent.
  expect(loads).toBe(GRAPH_LOCATE_PAGE_BUDGET);
  const locate = container.querySelector('[data-git-graph-target="missing"]')!;
  expect(locate).not.toBeNull();
  await click(locate);
  // The explicit click earns its own bounded locate run and reveals the row.
  expect(loads).toBe(GRAPH_LOCATE_PAGE_BUDGET + 1);
  expect(selected).toHaveBeenCalledTimes(1);
  expect(selected.mock.calls[0][0].hash).toBe("missing");
});

test("appending a page and repainting references preserve the manually scrolled viewport and selection", async () => {
  // The two pages are not a recorded Core history; this test asserts scrolling, not geometry.
  graphStub.mockRestore();
  graphStub = installGitGraphProjectionStub({ geometryFree: true });
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

test("a four-row viewport bounds graph nodes and paths across 5,000 commits without breaking boundary edges", async () => {
  const history = Array.from({ length: 5_000 }, (_, index) =>
    commit(String(index), index < 4_999 ? [String(index + 1)] : []),
  );
  await mount(history);
  const canvas = () => container.querySelector<SVGSVGElement>("[data-git-graph-canvas]")!;
  const edges = () => [...canvas().querySelectorAll("[data-git-graph-edges] > path")]
    .map((path) => path.getAttribute("d"));
  expect(container.querySelectorAll("[data-git-commit-hash]")).toHaveLength(4);
  expect(canvas().querySelectorAll("ellipse")).toHaveLength(5);
  expect(edges()).toHaveLength(5);
  expect(canvas().getAttribute("height")).toBe("130");
  expect(canvas().parentElement?.style.height).toBe("130000px");

  await act(async () => moveViewport?.(2_500));
  expect(container.querySelectorAll("[data-git-commit-hash]")).toHaveLength(4);
  expect(container.querySelector('[data-git-commit-hash="0"]')).toBeNull();
  expect(canvas().querySelectorAll("ellipse")).toHaveLength(6);
  expect(edges()).toHaveLength(7);
  expect(canvas().style.top).toBe("64974px");
  expect(canvas().getAttribute("height")).toBe("156");
  // Adjacent context rows complete both boundary connections on the same SVG.
  expect(edges()).toContain("M 9 13 L 9 26 L 9 39");
  expect(edges()).toContain("M 9 117 L 9 130 L 9 143");

  await act(async () => moveViewport?.(4_996));
  expect(canvas().querySelectorAll("ellipse")).toHaveLength(5);
  expect(edges()).toHaveLength(5);
  expect(canvas().style.top).toBe("129870px");
  expect(canvas().getAttribute("height")).toBe("130");

  await act(async () => moveViewport?.(0));
  expect(canvas().querySelectorAll("ellipse")).toHaveLength(5);
  expect(canvas().style.top).toBe("0px");
  expect(selected).not.toHaveBeenCalled();
});

test("an empty virtual range paints no graph and recovers when rows mount", async () => {
  windowSize = 0;
  await mount();
  expect(container.querySelector("[data-git-graph-canvas]")).toBeNull();
  expect(container.querySelectorAll("[data-git-commit-hash]")).toHaveLength(0);
  windowSize = 4;
  await act(async () => moveViewport?.(1));
  expect(container.querySelectorAll("[data-git-commit-hash]")).toHaveLength(4);
  expect(container.querySelectorAll("[data-git-graph-canvas] ellipse")).toHaveLength(6);
});

test("scrolling a one-row viewport preserves shifted fork paths through both neighboring rows", async () => {
  const parents = [["1"], ["3", "2"], ["3", "5"], ["5", "4"], ["5"], []];
  const history = parents.map((parentHashes, index) => ({
    ...commit(String(index), parentHashes),
    decorations: index === 0 ? "HEAD -> main" : index === 1 ? "feature" : "",
  }));
  windowSize = 1;
  await mount(history);
  const edges = () => [...container.querySelectorAll("[data-git-graph-edges] > path")]
    .map((path) => path.getAttribute("d"));

  await act(async () => moveViewport?.(4));
  expect(container.querySelectorAll("[data-git-commit-hash]")).toHaveLength(1);
  expect(container.querySelectorAll("[data-git-graph-canvas] ellipse")).toHaveLength(3);
  expect(container.querySelector<SVGSVGElement>("[data-git-graph-canvas]")!.style.top).toBe("78px");
  expect(edges()).toContain("M 26 13 L 34.5 26 L 43 39");
  expect(edges()).toContain("M 43 39 L 26 52 L 9 65");

  await act(async () => moveViewport?.(3));
  expect(edges()).toContain("M 26 39 L 34.5 52 L 43 65");
  expect(selected).not.toHaveBeenCalled();
});
