import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as virtual from "@tanstack/react-virtual";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit, GitReference } from "../../types/git.types";
import { GitCommitTable } from "./git-commit-table";

const longName = "origin/codex/frontend-preview-with-long-name";
const values: GitCommit[] = [
  ["main", ["a", "b"], "HEAD -> main, refs/remotes/upstream/release, tag: v1"],
  ["a", ["base"], ""],
  ["b", ["base"], ""],
  ["base", [], ""],
  ["other", [], `refs/remotes/${longName}`],
].map(([hash, parents, decorations]) => ({
  hash: hash as string,
  shortHash: hash as string,
  parentHashes: parents as string[],
  decorations: decorations as string,
  message: "Subject",
  author: "Fixture",
  date: "unknown",
}));
const current: GitReference = {
  fullName: "refs/heads/main",
  shortName: "main",
  kind: "local",
  isCurrent: true,
  peelsToCommit: true,
  upstreamShortName: "upstream/release",
};
const references: GitReference[] = [
  current,
  {
    fullName: "refs/remotes/upstream/release",
    shortName: "upstream/release",
    kind: "remote",
    isCurrent: false,
    peelsToCommit: true,
  },
];
let restoreDom: () => void;
let root: Root;
let container: HTMLElement;
let viewportSpy: ReturnType<typeof spyOn>;
let canvasSpy: ReturnType<typeof spyOn>;
let preferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
let observerDescriptor: PropertyDescriptor | undefined;
let actEnvironment: boolean | undefined;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const observers: Array<{ callback: ResizeObserverCallback; disconnected: boolean }> = [];
const noop = () => {};

function Harness({ scope = null }: { scope?: GitReference | null }) {
  const [selected, setSelected] = useState<GitCommit | null>(null);
  return (
    <LocaleProvider language="en-US">
      <GitCommitTable
        commits={values}
        repositoryCommits={values}
        references={references}
        selectedReference={scope}
        selectedCommit={selected}
        selectedCommitHashes={new Set(selected ? [selected.hash] : [])}
        navigationRequest={0}
        isMutatingHistory={false}
        hasMore={false}
        isLoadingMore={false}
        onSelect={setSelected}
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
    </LocaleProvider>
  );
}

beforeEach(() => {
  restoreDom = installHappyDom();
  actEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  preferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({ filterQuery: "", showDecorations: true });
  const style = document.createElement("style");
  style.textContent =
    `:root {--background:#191a1c;--foreground:#bcbec4;} .git-log-commit-text {color:var(--foreground);}` +
    readFileSync(new URL("./git-graph.css", import.meta.url), "utf8");
  document.head.append(style);
  viewportSpy = spyOn(virtual, "useVirtualizer").mockImplementation(((
    options: Parameters<typeof virtual.useVirtualizer>[0],
  ) => {
    const viewport = useRef({});
    Object.assign(viewport.current, {
      measure: noop,
      scrollToIndex: noop,
      getTotalSize: () => options.count * 26,
      getVirtualItems: () =>
        Array.from({ length: options.count }, (_, index) => ({
          index,
          key: index,
          start: index * 26,
          end: (index + 1) * 26,
          size: 26,
          lane: 0,
        })),
    });
    return viewport.current;
  }) as unknown as typeof virtual.useVirtualizer);
  canvasSpy = spyOn(window.HTMLCanvasElement.prototype, "getContext").mockImplementation((() => ({
    font: "",
    measureText: (text: string) => ({
      width: Array.from(text).length * 7,
      fontBoundingBoxAscent: 10,
      fontBoundingBoxDescent: 4,
    }),
  })) as unknown as typeof window.HTMLCanvasElement.prototype.getContext);
  observerDescriptor = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  observers.length = 0;
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: class {
      record: (typeof observers)[number];
      constructor(callback: ResizeObserverCallback) {
        this.record = { callback, disconnected: false };
        observers.push(this.record);
      }
      observe() {}
      disconnect() {
        this.record.disconnected = true;
      }
    },
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  viewportSpy.mockRestore();
  canvasSpy.mockRestore();
  if (observerDescriptor) Object.defineProperty(globalThis, "ResizeObserver", observerDescriptor);
  else Reflect.deleteProperty(globalThis, "ResizeObserver");
  useGitLogPreferencesStore.setState(preferences, true);
  environment.IS_REACT_ACT_ENVIRONMENT = actEnvironment;
  restoreDom();
});
const render = async (scope: GitReference | null = null) => {
  await act(async () => root.render(<Harness scope={scope} />));
};

for (const [theme, background, foreground] of [
  ["light", "#edf3ff", "#818594"],
  ["dark", "#1d2336", "#6f737a"],
]) {
  test(`${theme} actual table marks current-branch ancestry and dims every merge text column`, async () => {
    document.documentElement.dataset.themeType = theme;
    await render();
    const main = container.querySelector<HTMLElement>('[data-git-commit-hash="main"]')!;
    expect(main.dataset.currentBranch).toBe("true");
    expect(
      container.querySelector('[data-git-commit-hash="base"]')?.getAttribute("data-current-branch"),
    ).toBe("true");
    expect(
      container
        .querySelector('[data-git-commit-hash="other"]')
        ?.getAttribute("data-current-branch"),
    ).toBeNull();
    expect(getComputedStyle(main).backgroundColor).toBe(background);
    const cells = main.querySelectorAll(".git-log-commit-text");
    expect(cells).toHaveLength(3);
    for (const cell of cells) expect(getComputedStyle(cell).color).toBe(foreground);
    expect(main.querySelector("[data-git-reference-group]")?.textContent).toBe("upstream & main");
    expect(main.querySelector("[data-git-reference-group]")?.getAttribute("title")).toBe(
      "HEAD\nmain\nupstream/release\nv1",
    );
    await render(current);
    expect(main.getAttribute("data-current-branch")).toBeNull();
  });
}
test("reference clicks select the owning row; focus moves to files without clearing selection and window activity is local", async () => {
  await render();
  const main = container.querySelector<HTMLElement>('[data-git-commit-hash="main"]')!;
  await act(async () => main.querySelector<HTMLElement>("[data-git-reference-group]")!.click());
  expect(main.getAttribute("aria-pressed")).toBe("true");
  const viewport = container.querySelector<HTMLElement>("[data-scroll-container]")!;
  expect(document.activeElement).toBe(viewport);
  const files = document.createElement("button");
  container.append(files);
  files.focus();
  expect(main.getAttribute("aria-pressed")).toBe("true");
  expect(document.activeElement).toBe(files);
  window.dispatchEvent(new window.Event("blur"));
  expect(viewport.dataset.windowActive).toBe("false");
  window.dispatchEvent(new window.Event("focus"));
  expect(viewport.dataset.windowActive).toBe("true");
});
test("one viewport observer shortens long labels, retains their tooltip and releases on unmount", async () => {
  await render();
  expect(observers).toHaveLength(1);
  const viewport = container.querySelector<HTMLElement>("[data-scroll-container]")!;
  let width = 600;
  Object.defineProperty(viewport, "clientWidth", { configurable: true, get: () => width });
  const label = container.querySelector(
    '[data-git-commit-hash="other"] [data-git-reference-group]',
  )!;
  await act(async () => observers[0].callback([], {} as ResizeObserver));
  expect(label.textContent?.startsWith("../codex/")).toBe(true);
  expect(Array.from(label.textContent ?? "")).toHaveLength(22);
  expect(label.getAttribute("title")).toBe(longName);
  width = 2000;
  await act(async () => observers[0].callback([], {} as ResizeObserver));
  expect(label.textContent).toBe(longName);
  await act(async () => root.unmount());
  expect(observers[0].disconnected).toBe(true);
});
