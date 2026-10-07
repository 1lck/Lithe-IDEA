import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";

const menus = await import("@/ui/context-menu");
const virtualization = await import("@tanstack/react-virtual");
const dates = await import("./git-log-date-cell");
const { GitCommitTable } = await import("./git-commit-table");
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let previousPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
const spies: Array<{ mockRestore: () => void }> = [];
const onCreateTag = mock((_commit: GitCommit) => {});
const onSelect = mock(
  (..._args: Parameters<React.ComponentProps<typeof GitCommitTable>["onSelect"]>) => {},
);
const onOpenDiff = mock((_commit: GitCommit) => {});
const commits: GitCommit[] = ["a", "b"].map((letter, index) => ({
  hash: letter.repeat(40),
  shortHash: letter.repeat(7),
  parentHashes: index === 0 ? ["b".repeat(40)] : [],
  message: `Commit ${letter}`,
  author: "Developer",
  date: "2026/10/06 10:00",
  decorations: index === 0 ? "HEAD -> main" : "",
}));
const content = ({ children }: { children?: unknown }) => (
  <div>{typeof children === "function" ? null : (children as ReactNode)}</div>
);

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  previousPreferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({ filterQuery: "", filterScope: "text" });
  onCreateTag.mockClear();
  onSelect.mockClear();
  onOpenDiff.mockClear();
  // Deterministic visible rows and inline menus let us click the actual commit
  // action without relying on browser layout, popup placement, or date timers.
  spies.push(
    spyOn(virtualization, "useVirtualizer").mockImplementation(((options: { count: number }) => ({
      getVirtualItems: () =>
        commits
          .slice(0, options.count)
          .map((commit, index) => ({ index, key: commit.hash, start: index * 30, size: 30 })),
      getTotalSize: () => options.count * 30,
      measure: () => {},
      scrollToIndex: () => {},
    })) as unknown as typeof virtualization.useVirtualizer),
    spyOn(menus, "ContextMenu").mockImplementation(content),
    spyOn(menus, "ContextMenuTrigger").mockImplementation(({ children, ...props }) => (
      <div {...(props as React.HTMLAttributes<HTMLDivElement>)}>{children as ReactNode}</div>
    )),
    spyOn(menus, "ContextMenuContent").mockImplementation(content),
    spyOn(menus, "ContextMenuItem").mockImplementation(({ children, disabled, onClick }) => (
      <button
        disabled={disabled}
        onClick={(event) =>
          onClick?.(event as unknown as Parameters<NonNullable<typeof onClick>>[0])
        }
      >
        {children}
      </button>
    )),
    spyOn(menus, "ContextMenuSeparator").mockImplementation(() => <hr />),
    spyOn(menus, "ContextMenuShortcut").mockImplementation(content),
    spyOn(dates, "GitLogDateCell").mockImplementation(() => <span />),
  );
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    useGitLogPreferencesStore.setState(previousPreferences);
    container.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

function TableHarness({
  initialSelection,
  isMutatingHistory,
}: {
  initialSelection: Set<string>;
  isMutatingHistory: boolean;
}) {
  const [selectedCommit, setSelectedCommit] = useState<GitCommit | null>(
    commits.find((commit) => initialSelection.has(commit.hash)) ?? null,
  );
  const [selectedCommitHashes, setSelectedCommitHashes] = useState(initialSelection);
  return (
    <GitCommitTable
      commits={commits}
      selectedCommit={selectedCommit}
      selectedCommitHashes={selectedCommitHashes}
      isMutatingHistory={isMutatingHistory}
      hasMore={false}
      isLoadingMore={false}
      onSelect={(commit, hashes, options) => {
        onSelect(commit, hashes, options);
        setSelectedCommit(commit);
        setSelectedCommitHashes(new Set([commit.hash]));
      }}
      onContextSelect={() => {}}
      onOpenDiff={onOpenDiff}
      onCompareWithHead={() => {}}
      onCopyHash={() => {}}
      onCopyShortHash={() => {}}
      onCopyMessage={() => {}}
      onEditMessage={() => {}}
      onUndo={() => {}}
      onInteractiveRebase={() => {}}
      onExportPatch={() => {}}
      onDelete={() => {}}
      onSquash={() => {}}
      onReset={() => {}}
      onCherryPick={() => {}}
      onRevert={() => {}}
      onCreateTag={onCreateTag}
      onLoadMore={() => {}}
    />
  );
}
const renderTable = async (selectedCommitHashes: Set<string>, isMutatingHistory = false) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <TableHarness
          key={`${[...selectedCommitHashes].join()}:${isMutatingHistory}`}
          initialSelection={selectedCommitHashes}
          isMutatingHistory={isMutatingHistory}
        />
      </LocaleProvider>,
    ),
  );
};
const tagButtons = () =>
  Array.from(container.querySelectorAll<HTMLButtonElement>("button")).filter(
    (button) => button.textContent === "New Tag…",
  );

test("New Tag targets the context commit rather than HEAD or the previous selection", async () => {
  await renderTable(new Set([commits[0]!.hash]));
  expect(tagButtons()).toHaveLength(2);
  await act(async () => tagButtons()[1]!.click());
  expect(onCreateTag.mock.calls).toEqual([[commits[1]!]]);
});

test("New Tag is disabled for multiple selected commits and during mutations", async () => {
  await renderTable(new Set(commits.map((commit) => commit.hash)));
  expect(tagButtons()).toHaveLength(2);
  expect(tagButtons().every((button) => button.disabled)).toBe(true);
  await act(async () => tagButtons()[1]!.click());
  await renderTable(new Set([commits[1]!.hash]), true);
  expect(tagButtons().every((button) => button.disabled)).toBe(true);
  await act(async () => tagButtons()[1]!.click());
  expect(onCreateTag).not.toHaveBeenCalled();
});

const viewport = () => container.querySelector<HTMLElement>("[data-scroll-container]")!;
const row = (index: number) =>
  container.querySelector<HTMLElement>(`[data-git-commit-index="${index}"]`)!;
const press = async (key: string, options: KeyboardEventInit = {}, target = viewport()) =>
  act(async () => {
    target.dispatchEvent(
      new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...options }),
    );
  });

test("Clicking commit content gives the list focus and arrow keys change the active commit", async () => {
  await renderTable(new Set([commits[0]!.hash]));
  await act(async () => row(0).querySelector("span")!.click());
  expect(document.activeElement === viewport()).toBe(true);
  await press("ArrowDown");
  expect(row(1).getAttribute("aria-pressed")).toBe("true");
  expect(onSelect.mock.calls[onSelect.mock.calls.length - 1]?.[0]).toEqual(commits[1]);
  expect(document.activeElement === viewport()).toBe(true);
  // A context menu can restore focus to its trigger; navigation returns it to
  // the stable viewport before virtualization can remove that row.
  row(1).focus();
  await press("ArrowUp", {}, row(1));
  expect(row(0).getAttribute("aria-pressed")).toBe("true");
  await press("Enter");
  expect(onOpenDiff.mock.calls).toEqual([[commits[0]!]]);
});

test("Keyboard navigation handles empty selection and both list boundaries", async () => {
  await renderTable(new Set());
  viewport().focus();
  await press("ArrowDown");
  expect(row(0).getAttribute("aria-pressed")).toBe("true");
  await press("ArrowUp");
  expect(row(0).getAttribute("aria-pressed")).toBe("true");
  await press("End");
  await press("ArrowDown");
  expect(row(1).getAttribute("aria-pressed")).toBe("true");
  await press("Home");
  expect(row(0).getAttribute("aria-pressed")).toBe("true");
});

test("Shift navigation preserves range intent and filtering skips hidden commits", async () => {
  await renderTable(new Set([commits[0]!.hash]));
  await press("ArrowDown", { shiftKey: true });
  expect(onSelect.mock.calls[0]?.[2]).toEqual({ additive: false, range: true });
  await act(async () => useGitLogPreferencesStore.setState({ filterQuery: "Commit a" }));
  await press("ArrowUp");
  expect(onSelect.mock.calls[onSelect.mock.calls.length - 1]?.[1]).toEqual([commits[0]!.hash]);
  expect(row(0).getAttribute("aria-pressed")).toBe("true");
});

test("Input and menu buttons retain their own arrow keys", async () => {
  await renderTable(new Set([commits[0]!.hash]));
  await press("ArrowDown", {}, container.querySelector<HTMLInputElement>("input")!);
  await press("ArrowDown", {}, tagButtons()[0]!);
  expect(onSelect).not.toHaveBeenCalled();
});
