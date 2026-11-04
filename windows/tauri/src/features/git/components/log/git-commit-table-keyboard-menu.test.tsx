import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { createRequire } from "node:module";
import { act, useState, useLayoutEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit } from "../../types/git.types";
import * as historyApi from "../../api/git-history-rewrite-api";
import * as commitsApi from "../../api/git-commits-api";
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
const onCherryPick = mock((_commit: GitCommit) => {});
const onSquash = mock((_commits: GitCommit[]) => {});
let capabilitySpy: ReturnType<typeof spyOn<typeof historyApi, "getGitHistoryActionCapabilities">>;
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
  onCherryPick.mockClear();
  onSquash.mockClear();
  contextCommit.mockClear();
  emptyMenu.mockClear();
  capabilitySpy = spyOn(historyApi, "getGitHistoryActionCapabilities").mockImplementation(async (_root, revisions) => ({
    head: commits[1]!.hash, canCherryPick: revisions[0] !== commits[1]!.hash,
    canUndo: revisions[0] === commits[1]!.hash, canSquash: false,
  }));
  spies.push(capabilitySpy);
  spies.push(spyOn(commitsApi, "cancelGitHistoryOperation").mockResolvedValue(undefined));
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
    commits.forEach((commit) => {
      commit.decorations = "";
    });
    spies.splice(0).forEach((spy) => spy.mockRestore());
    useGitLogPreferencesStore.setState(previousPreferences);
    host.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
function Harness({ selected = true, selectedHashes }: { selected?: boolean; selectedHashes?: Set<string> }) {
  const [commit, setCommit] = useState<GitCommit | null>(selected ? commits[0]! : null);
  return (
    <div
      onContextMenu={(event) => {
        if (!(event.target as HTMLElement).closest('[data-slot="context-menu-trigger"]'))
          emptyMenu();
      }}
    >
      <GitCommitTable
        repoPath="C:/repo"
        commits={commits}
        selectedCommit={commit}
        selectedCommitHashes={selectedHashes ?? new Set(commit ? [commit.hash] : [])}
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
        onSquash={onSquash}
        onReset={() => {}}
        onCherryPick={onCherryPick}
        onRevert={() => {}}
        onLoadMore={() => {}}
        onSelectReference={() => {}}
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

test("cherry-pick is enabled for another branch tip at the first row", async () => {
  commits[1]!.decorations = "HEAD -> main";
  await render();
  viewport().focus();
  await key("ContextMenu");
  const item = Array.from(openMenu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')).find(
    (entry) => entry.textContent === "Cherry-pick Commit",
  )!;
  expect(item.getAttribute("aria-disabled")).not.toBe("true");
  await act(async () => item.click());
  expect(onCherryPick.mock.calls).toEqual([[commits[0]!]]);
});

test("cherry-pick is disabled for actual HEAD even when it is not the first row", async () => {
  commits[1]!.decorations = "HEAD -> main";
  await render();
  viewport().focus();
  await key("ArrowDown");
  await key("ContextMenu");
  const item = Array.from(openMenu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')).find(
    (entry) => entry.textContent === "Cherry-pick Commit",
  )!;
  expect(item.getAttribute("aria-disabled")).toBe("true");
  await act(async () => item.click());
  expect(onCherryPick).not.toHaveBeenCalled();
});


test("squash uses Core eligibility even when the loaded graph lacks its parent chain", async () => {
  capabilitySpy.mockResolvedValue({head: "other", canCherryPick: false, canUndo: false, canSquash: true});
  await act(async () => root.render(<LocaleProvider language="en-US"><Harness selectedHashes={new Set(commits.map((commit) => commit.hash))} /></LocaleProvider>));
  viewport().focus();
  await key("ContextMenu");
  const item = Array.from(openMenu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')).find(
    (entry) => entry.textContent === "Squash Commits",
  );
  expect(item).toBeDefined();
  expect(item!.getAttribute("aria-disabled")).not.toBe("true");
  await act(async () => item!.click());
  expect(onSquash.mock.calls[0]?.[0].map((commit) => commit.hash)).toEqual(commits.map((commit) => commit.hash));
});
