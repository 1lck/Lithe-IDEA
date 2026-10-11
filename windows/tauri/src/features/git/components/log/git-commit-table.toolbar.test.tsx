import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as virtual from "@tanstack/react-virtual";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit, GitReference } from "../../types/git.types";
import { GitCommitTable } from "./git-commit-table";

let restoreDom: () => void;
let container: HTMLElement;
let root: Root;
let viewportSpy: ReturnType<typeof spyOn>;
let previousPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

const commits: GitCommit[] = ["a", "b"].map((hash, row) => ({
  hash,
  shortHash: hash,
  parentHashes: row === 0 ? ["b"] : [],
  message: row === 0 ? "alpha" : "beta",
  author: "dev",
  date: "unknown",
  decorations: "",
}));
const references: GitReference[] = [
  { fullName: "refs/heads/main", shortName: "main", kind: "local", peelsToCommit: true, isCurrent: true },
  { fullName: "refs/heads/feature", shortName: "feature", kind: "local", peelsToCommit: true, isCurrent: false },
];

beforeEach(() => {
  restoreDom = installHappyDom();
  (globalThis as { ResizeObserver?: unknown }).ResizeObserver = StubResizeObserver;
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousPreferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({ filterQuery: "", filterScope: "text" });
  // Control the viewport only; the real table computes matches and graph rows.
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
  delete (globalThis as { ResizeObserver?: unknown }).ResizeObserver;
  useGitLogPreferencesStore.setState(previousPreferences, true);
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

// The Dropdown observes its own size; happy-dom has no ResizeObserver.
class StubResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}

async function renderTable(
  onSelectReference: (reference: GitReference | null) => void,
  selectedReference: GitReference | null = null,
) {
  const noop = () => {};
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <GitCommitTable
          commits={commits}
          references={references}
          selectedReference={selectedReference}
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
          onSelectReference={onSelectReference}
        />
      </LocaleProvider>,
    );
  });
}

function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

test("the text filter searches only when Enter is pressed and clears immediately", async () => {
  await renderTable(() => {});
  const input = container.querySelector<HTMLInputElement>("input")!;
  // happy-dom has no native input event support, so React detects a value change from a
  // keyup on the focused input; emulate typing as value + keyup.
  input.focus();
  await act(async () => {
    typeInto(input, "alpha");
    input.dispatchEvent(new KeyboardEvent("keyup", { key: "a", bubbles: true }));
  });
  expect(useGitLogPreferencesStore.getState().filterQuery).toBe("");
  expect(container.querySelectorAll("[data-git-commit-index]")).toHaveLength(2);

  await act(async () => {
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(useGitLogPreferencesStore.getState().filterQuery).toBe("alpha");
  expect(container.querySelectorAll("[data-git-commit-index]")).toHaveLength(1);

  await act(async () =>
    container.querySelector<HTMLButtonElement>('button[aria-label="Clear Git log filter"]')?.click(),
  );
  expect(useGitLogPreferencesStore.getState().filterQuery).toBe("");
  expect(input.value).toBe("");
});

test("the draft follows an external filter change", async () => {
  await renderTable(() => {});
  await act(async () => useGitLogPreferencesStore.getState().actions.setFilterQuery("beta"));
  expect(container.querySelector<HTMLInputElement>("input")!.value).toBe("beta");
});

test("the Branch filter lists references and applies the chosen one", async () => {
  const selected: Array<GitReference | null> = [];
  await renderTable((reference) => selected.push(reference));
  const trigger = container.querySelector<HTMLButtonElement>('button[aria-haspopup="menu"]')!;
  expect(trigger.textContent).toContain("Branch: All");
  await act(async () => trigger.click());
  const feature = [
    ...document.querySelectorAll<HTMLElement>('[role="menu"] button, [role="menu"] [role="menuitem"]'),
  ].find((item) => item.textContent?.trim() === "feature");
  expect(feature).toBeDefined();
  await act(async () => feature!.click());
  expect(selected.map((reference) => reference?.fullName)).toEqual(["refs/heads/feature"]);
});

test("the Branch filter sits after the text filter and its x returns to All", async () => {
  const selected: Array<GitReference | null> = [];
  await renderTable((reference) => selected.push(reference), references[1]);
  const trigger = container.querySelector<HTMLButtonElement>('button[aria-haspopup="menu"]')!;
  expect(trigger.textContent).toContain("Branch: feature");
  const input = container.querySelector("input")!;
  // Document order: text filter first, Branch filter to its right.
  expect(input.compareDocumentPosition(trigger) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  await act(async () =>
    container.querySelector<HTMLButtonElement>('button[aria-label="Clear branch filter"]')?.click(),
  );
  expect(selected).toEqual([null]);
});

test("no clear button is offered while the Branch filter is All", async () => {
  await renderTable(() => {});
  expect(container.querySelector('button[aria-label="Clear branch filter"]')).toBeNull();
});

test("the open Branch menu applies wheel deltas to its own scroller", async () => {
  await renderTable(() => {});
  await act(async () =>
    container.querySelector<HTMLButtonElement>('button[aria-haspopup="menu"]')!.click(),
  );
  // The menu binds its wheel handler once its scroller has mounted, at most a frame later.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  const scroller = menu.parentElement!;
  // happy-dom loads no CSS and does no layout: declare the scroller and its overflowing content,
  // otherwise the popover's own wheel guard treats it as unscrollable.
  scroller.style.overflowY = "auto";
  Object.defineProperty(scroller, "scrollHeight", { configurable: true, value: 1000 });
  Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 200 });
  const wheel = new window.WheelEvent("wheel", {
    deltaX: 0,
    deltaY: 60,
    bubbles: true,
    cancelable: true,
  });
  menu.dispatchEvent(wheel);
  expect(scroller.scrollTop).toBe(60);
  expect(wheel.defaultPrevented).toBe(true);
});
