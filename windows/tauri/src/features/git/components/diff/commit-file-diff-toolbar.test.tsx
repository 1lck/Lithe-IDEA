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
  expect(highlight().textContent).toBe("Highlight words");
  expect(highlight().getAttribute("aria-pressed")).toBe("true");
  await act(async () => highlight().click());
  await render(false, true);
  expect(highlight().getAttribute("aria-pressed")).toBe("false");
  await render(false, false);
  expect(highlight().disabled).toBe(true);
  await act(async () => highlight().click());
  expect(actions).toEqual(["highlight"]);
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
