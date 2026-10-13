import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { createRequire } from "node:module";
import { act, useState, useLayoutEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
const { GitCommitTable } = await import("./git-commit-table");
const virtualization = await import("@tanstack/react-virtual");
const dates = await import("./git-log-date-cell");
const layoutEffectPath = createRequire(import.meta.resolve("@base-ui/react"))
  .resolve("@base-ui/utils/useIsoLayoutEffect")
  .replace(/\.js$/, ".mjs");
const baseLayoutEffects = await import(layoutEffectPath);
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let root: Root;
let host: HTMLDivElement;
let previousPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
const spies: Array<{ mockRestore(): void }> = [];
const onCreateTag = mock((_commit: GitCommit) => {});
const contextCommit = mock((_commit: GitCommit) => {});
const emptyMenu = mock(() => {});
const commits: GitCommit[] = ["a", "b"].map((letter) => ({
  hash: letter.repeat(40),
  shortHash: letter.repeat(7),
  parentHashes: [],
  message: `Commit ${letter}`,
  author: "Developer",
  date: "2026/10/06 10:00",
  decorations: "",
}));
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  previousPreferences = useGitLogPreferencesStore.getState();
  useGitLogPreferencesStore.setState({ filterQuery: "", filterScope: "text" });
  onCreateTag.mockClear();
  contextCommit.mockClear();
  emptyMenu.mockClear();
  // Other tests can import Base UI before installing a DOM, choosing its SSR
  // no-op hook. Enable the real React client hook for this owned DOM fixture.
  spies.push(spyOn(baseLayoutEffects, "useIsoLayoutEffect").mockImplementation(useLayoutEffect));
  // Only layout and date presentation are replaced. Menu, trigger, popup and
  // portal remain the production Base UI components.
  spies.push(
    spyOn(virtualization, "useVirtualizer").mockImplementation(((options: { count: number }) => ({
      getVirtualItems: () =>
        commits.slice(0, options.count).map((commit, index) => ({
          index,
          key: commit.hash,
          start: index * 30,
          size: 30,
        })),
      getTotalSize: () => options.count * 30,
      measure: () => {},
      scrollToIndex() {},
    })) as unknown as typeof virtualization.useVirtualizer),
  );
  spies.push(spyOn(dates, "GitLogDateCell").mockImplementation(() => <span />));
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    spies.splice(0).forEach((spy) => spy.mockRestore());
    useGitLogPreferencesStore.setState(previousPreferences);
    host.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
function Harness({ selected = true }: { selected?: boolean }) {
  const [commit, setCommit] = useState<GitCommit | null>(selected ? commits[0]! : null);
  return (
    <div
      onContextMenu={(event) => {
        if (!(event.target as HTMLElement).closest('[data-slot="context-menu-trigger"]'))
          emptyMenu();
      }}
    >
      <GitCommitTable
        commits={commits}
        selectedCommit={commit}
        selectedCommitHashes={new Set(commit ? [commit.hash] : [])}
        isMutatingHistory={false}
        hasMore={false}
        isLoadingMore={false}
        onSelect={setCommit}
        onContextSelect={contextCommit}
        onCreateTag={onCreateTag}
        onOpenDiff={() => {}}
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
        onLoadMore={() => {}}
      />
    </div>
  );
}
const render = async (selected = true) =>
  act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <Harness selected={selected} />
      </LocaleProvider>,
    ),
  );
const viewport = () => host.querySelector<HTMLElement>("[data-scroll-container]")!;
const key = async (key: string, shiftKey = false, target: HTMLElement = viewport()) =>
  act(async () => {
    target.dispatchEvent(
      new window.KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true }),
    );
  });
const openMenu = () =>
  document.querySelector<HTMLElement>('[data-slot="context-menu-content"][data-open]');
for (const [keyName, shiftKey] of [
  ["ContextMenu", false],
  ["F10", true],
] as const) {
  test(`${keyName} opens the selected commit's real menu after arrow navigation`, async () => {
    await render();
    viewport().focus();
    await key("ArrowDown");
    await key(keyName, shiftKey);
    expect(openMenu()).not.toBeNull();
    expect(emptyMenu).not.toHaveBeenCalled();
    expect(contextCommit.mock.calls).toEqual([[commits[1]!]]);
    const tag = Array.from(openMenu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')).find(
      (item) => item.textContent === "New Tag…",
    )!;
    await act(async () => tag.click());
    expect(onCreateTag.mock.calls).toEqual([[commits[1]!]]);
  });
}
test("Native viewport contextmenu routes to the selected commit", async () => {
  await render();
  viewport().focus();
  await act(async () =>
    viewport().dispatchEvent(
      new window.MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 0,
        clientY: 0,
      }),
    ),
  );
  expect(openMenu()).not.toBeNull();
  expect(emptyMenu).not.toHaveBeenCalled();
  expect(contextCommit.mock.calls).toEqual([[commits[0]!]]);
});
test("No selection does not open an unrelated commit menu", async () => {
  await render(false);
  viewport().focus();
  await key("ContextMenu");
  expect(openMenu()).toBeNull();
  expect(contextCommit).not.toHaveBeenCalled();
});

test("Escape closes the real menu and returns focus to the stable viewport", async () => {
  await render();
  viewport().focus();
  await key("ContextMenu");
  const menu = openMenu()!;
  expect(menu).not.toBeNull();
  // Portal keyboard events must not reopen or retarget the commit menu.
  await key("F10", true, menu);
  expect(contextCommit.mock.calls).toHaveLength(1);
  await key("Escape", false, menu);
  expect(openMenu()).toBeNull();
  await act(async () => {
    await Promise.resolve();
  });
  expect(document.activeElement === viewport()).toBe(true);
  await key("ArrowDown");
  expect(host.querySelector('[data-git-commit-index="1"]')?.getAttribute("aria-pressed")).toBe(
    "true",
  );
});
