import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { commitDifferenceNavigation, emptyDiffNavigation } from "../../utils/commit-file-diff-navigation";
import { CommitFileDiffToolbar } from "./commit-file-diff-toolbar";
import { CommitFileDiffVersionHeader } from "./commit-file-diff-version-header";

let restoreDom: () => void;
let container: HTMLElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

test("down arrow remains available at the last difference while a next file exists", async () => {
  const actions: string[] = [];
  const render = async (ready: boolean, fileIndex: number) => act(async () => root.render(
    <LocaleProvider language="en-US">
      <CommitFileDiffToolbar
        navigation={commitDifferenceNavigation({ ...emptyDiffNavigation, ready }, fileIndex, 3)}
        fileIndex={fileIndex} fileCount={3} viewMode="split" canSplit showWhitespace={false}
        onDifference={(direction) => actions.push(direction)} onFile={() => {}}
        onSource={() => {}} onViewMode={() => {}} onWhitespace={() => {}}
        highlightWords canHighlightWords onHighlightWords={() => {}}
      />
    </LocaleProvider>,
  ));
  await render(true, 0);
  expect(button("Next Difference").disabled).toBe(false);
  await act(async () => button("Next Difference").click());
  await render(false, 1);
  expect(button("Next Difference").disabled).toBe(true);
  await act(async () => button("Next Difference").click());
  await render(true, 1);
  await act(async () => button("Next Difference").click());
  await render(true, 2);
  expect(button("Next Difference").disabled).toBe(true);
  await act(async () => button("Next Difference").click());
  expect(actions).toEqual(["next", "next"]);
});

test("up arrow can leave the first difference for a previous file and waits during loading", async () => {
  const actions: string[] = [];
  const render = async (ready: boolean, index: number) => act(async () => root.render(
    <LocaleProvider language="en-US">
      <CommitFileDiffToolbar navigation={commitDifferenceNavigation({ ...emptyDiffNavigation, ready }, index, 3)}
        fileIndex={index} fileCount={3} viewMode="split" canSplit showWhitespace={false}
        highlightWords canHighlightWords onHighlightWords={() => {}}
        onDifference={direction => actions.push(direction)} onFile={() => {}} onSource={() => {}}
        onViewMode={() => {}} onWhitespace={() => {}} />
    </LocaleProvider>,
  ));
  await render(true, 2);
  expect(button("Previous Difference").disabled).toBe(false);
  await act(async () => button("Previous Difference").click());
  await render(false, 1);
  expect(button("Previous Difference").disabled).toBe(true);
  await render(true, 1);
  await act(async () => button("Previous Difference").click());
  await render(true, 0);
  expect(button("Previous Difference").disabled).toBe(true);
  expect(actions).toEqual(["previous", "previous"]);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
const button = (label: string) =>
  container.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;

test("whole-file additions and deletions show only the existing revision title", async () => {
  const diff = { file_path: "file.ts", is_new: true, is_deleted: false, is_renamed: false, lines: [] };
  await act(async () => root.render(<LocaleProvider language="en-US">
    <CommitFileDiffVersionHeader diff={diff} revisions={{ before: "parent123", after: "target123" }} label="unused" viewMode="unified" />
  </LocaleProvider>));
  expect(container.querySelectorAll(".commit-diff-version")).toHaveLength(1);
  expect(container.querySelector('[data-revision-side="after"]')!.textContent).toBe("target12file.ts");
  await act(async () => root.render(<LocaleProvider language="en-US">
    <CommitFileDiffVersionHeader diff={{ ...diff, is_new: false, is_deleted: true }}
      revisions={{ before: "parent123", after: "target123" }} label="unused" viewMode="split" />
  </LocaleProvider>));
  expect(container.querySelectorAll(".commit-diff-version")).toHaveLength(1);
  expect(container.querySelector('[data-revision-side="before"]')!.textContent).toBe("parent12file.ts");
});

test("worktree titles use HEAD and current version with a file inclusion checkbox", async () => {
  const toggles: boolean[] = [];
  await act(async () => root.render(<LocaleProvider language="en-US">
    <CommitFileDiffVersionHeader diff={{ file_path: "file.ts", is_new: false, is_deleted: false, is_renamed: false, lines: [] }}
      label="working-tree" viewMode="split" workingTree={{ staged: false, included: true,
        indeterminate: true, disabled: false, onToggle: checked => toggles.push(checked) }} />
  </LocaleProvider>));
  expect(container.querySelector('[data-revision-side="before"]')!.textContent).toBe("HEADfile.ts");
  expect(container.querySelector('[data-revision-side="after"]')!.textContent).toBe("Current versionfile.ts");
  const checkbox = container.querySelector<HTMLButtonElement>('[role="checkbox"]')!;
  expect(checkbox.getAttribute("aria-checked")).toBe("mixed");
  await act(async () => checkbox.click());
  expect(toggles).toEqual([true]);
});

test("toolbar respects ready/deleted/file-boundary states and dispatches distinct navigation actions", async () => {
  const actions: Array<string | number> = [];
  const render = async (ready: boolean, fileIndex: number) =>
    act(async () =>
      root.render(
        <LocaleProvider language="en-US">
          <CommitFileDiffToolbar
            navigation={
              ready
                ? { ready: true, count: 2, canPrevious: true, canNext: true, canJumpToSource: true }
                : emptyDiffNavigation
            }
            fileIndex={fileIndex}
            fileCount={3}
            viewMode="split"
            canSplit
            showWhitespace={false}
            onDifference={(direction) => actions.push(direction)}
            onFile={(direction) => actions.push(direction)}
            onSource={() => actions.push("source")}
            onViewMode={(mode) => actions.push(mode)}
            onWhitespace={() => actions.push("whitespace")}
            highlightWords canHighlightWords onHighlightWords={() => actions.push("highlight")}
          />
        </LocaleProvider>,
      ),
    );
  await render(false, 0);
  for (const label of ["Previous Difference", "Next Difference", "Jump to Source", "Previous File"])
    expect(button(label).disabled).toBe(true);
  expect(button("Next File").disabled).toBe(false);
  await render(true, 1);
  await act(async () => {
    for (const label of [
      "Previous Difference",
      "Next Difference",
      "Jump to Source",
      "Previous File",
      "Next File",
    ])
      button(label).click();
  });
  expect(actions).toEqual(["previous", "next", "source", -1, 1]);
  await render(false, 2);
  expect(button("Next File").disabled).toBe(true);
  expect(button("Jump to Source").disabled).toBe(true);
});

test("word highlighting is a pressed toggle and unavailable for binary reviews", async () => {
  const actions: string[] = [];
  const render = async (highlightWords: boolean, canHighlightWords: boolean) => act(async () => root.render(
    <LocaleProvider language="en-US">
      <CommitFileDiffToolbar navigation={emptyDiffNavigation} fileIndex={0} fileCount={1}
        viewMode="split" canSplit showWhitespace={false} highlightWords={highlightWords}
        canHighlightWords={canHighlightWords} onHighlightWords={() => actions.push("highlight")}
        onDifference={() => {}} onFile={() => {}} onSource={() => {}}
        onViewMode={() => {}} onWhitespace={() => {}} />
    </LocaleProvider>,
  ));
  const highlight = () => container.querySelector<HTMLButtonElement>('button[aria-pressed]:not([aria-label])')!;
  await render(true, true);
  expect(highlight().textContent).toBe("Highlight Words");
  expect(highlight().getAttribute("aria-pressed")).toBe("true");
  await act(async () => highlight().click());
  await render(false, true);
  expect(highlight().getAttribute("aria-pressed")).toBe("false");
  await render(false, false);
  expect(highlight().disabled).toBe(true);
  await act(async () => highlight().click());
  expect(actions).toEqual(["highlight"]);
});

test("display controls precede the rightmost difference status and keep toggle semantics", async () => {
  const actions: string[] = [];
  const render = async (showWhitespace: boolean, viewMode: "split" | "unified") => act(async () => root.render(
    <LocaleProvider language="en-US">
      <CommitFileDiffToolbar navigation={{ ...emptyDiffNavigation, ready: true, count: 3 }}
        fileIndex={1} fileCount={5} viewMode={viewMode} canSplit showWhitespace={showWhitespace}
        highlightWords canHighlightWords onHighlightWords={() => actions.push("words")}
        onDifference={() => {}} onFile={() => {}} onSource={() => {}}
        onViewMode={mode => actions.push(mode)} onWhitespace={() => actions.push("whitespace")}
        onRefresh={() => actions.push("refresh")} />
    </LocaleProvider>,
  ));
  await render(false, "split");
  const toolbar = container.querySelector('[role="toolbar"]')!;
  const status = toolbar.querySelector('[role="status"]')!;
  const controls = toolbar.querySelector(".commit-diff-toolbar-actions")!;
  expect(toolbar.lastElementChild).toBe(status);
  expect(controls.contains(status)).toBe(false);
  expect(controls.contains(button("Unified viewer"))).toBe(true);
  expect(controls.contains(button("Side-by-side viewer"))).toBe(true);
  expect(status.textContent).toBe("3 differences");
  const whitespace = () => [...toolbar.querySelectorAll<HTMLButtonElement>("button")]
    .find(control => control.textContent === "Show Whitespaces")!;
  expect(whitespace().getAttribute("aria-pressed")).toBe("false");
  await act(async () => {
    whitespace().click();
    button("Unified viewer").click();
    button("Side-by-side viewer").click();
    button("Refresh").click();
  });
  expect(actions).toEqual(["whitespace", "unified", "split", "refresh"]);
  await render(true, "unified");
  expect(whitespace().getAttribute("aria-pressed")).toBe("true");
  expect(button("Unified viewer").getAttribute("aria-pressed")).toBe("true");
  expect(button("Side-by-side viewer").getAttribute("aria-pressed")).toBe("false");
  expect(status.textContent).toBe("3 differences");
});

test("difference status uses IDEA singular, plural and inclusion counts without loading or binary claims", async () => {
  const render = async (count: number, includedCount?: number, ready = true, canHighlightWords = true,
    fileNavigationBusy = false, language: "en-US" | "zh-CN" = "en-US", differenceCount?: number) => act(async () => root.render(
    <LocaleProvider language={language}>
      <CommitFileDiffToolbar navigation={{ ...emptyDiffNavigation, ready, count }}
        fileIndex={0} fileCount={9} viewMode="split" canSplit showWhitespace={false}
        fileNavigationBusy={fileNavigationBusy} includedCount={includedCount} differenceCount={differenceCount}
        highlightWords canHighlightWords={canHighlightWords} onHighlightWords={() => {}}
        onDifference={() => {}} onFile={() => {}} onSource={() => {}}
        onViewMode={() => {}} onWhitespace={() => {}} />
    </LocaleProvider>,
  ));
  const status = () => container.querySelector('[role="status"]')!.textContent;
  for (const [count, expected] of [[0, "No differences"], [1, "1 difference"], [4, "4 differences"]] as const) {
    await render(count);
    expect(status()).toBe(expected);
  }
  for (const included of [0, 2, 4]) {
    await render(4, included);
    expect(status()).toBe(`4 differences, ${included} included`);
  }
  await render(1, 1);
  expect(status()).toBe("1 difference, 1 included");
  // Unified comparison can merge nearby changes; Commit still counts its visible inclusion blocks.
  await render(1, 2, true, true, false, "en-US", 4);
  expect(status()).toBe("4 differences, 2 included");
  await render(4, 2, false);
  expect(status()).toBe("");
  await render(4, 2, true, false);
  expect(status()).toBe("");
  await render(4, 2, true, true, true);
  expect(status()).toBe("");
  await render(4, 2, true, true, false, "zh-CN");
  expect(status()).toBe("4 处差异，已包含 2 处");
});

test("version titles preserve rename paths, exact revision tooltips and empty-tree identity", async () => {
  const diff = { file_path: "new.ts", old_path: "old.ts", new_path: "new.ts", is_renamed: true,
    is_new: false, is_deleted: false, lines: [] };
  const render = async (before: string | null, viewMode: "split" | "unified") => act(async () => root.render(
    <LocaleProvider language="en-US"><CommitFileDiffVersionHeader diff={diff}
      revisions={{ before, after: "target123456789" }} label="unused" viewMode={viewMode} /></LocaleProvider>,
  ));
  await render("parent123456789", "split");
  const left = container.querySelector('[data-revision-side="before"]')!;
  const right = container.querySelector('[data-revision-side="after"]')!;
  expect(left.textContent).toBe("parent12old.ts");
  expect(right.textContent).toBe("target12new.ts");
  expect(left.querySelector('[title="parent123456789"]')).not.toBeNull();
  expect(right.querySelector('[title="target123456789"]')).not.toBeNull();
  await render(null, "unified");
  expect(container.querySelector('[data-revision-side="before"]')!.textContent).toBe("Emptyold.ts");
  expect(container.querySelector('[data-view-mode]')!.getAttribute("data-view-mode")).toBe("unified");
});
