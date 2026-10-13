import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ChangeEvent } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { InputProps } from "@/ui/input";
import type { GitCommit } from "../../types/git.types";

const dialogs = await import("@/ui/dialog");
const inputs = await import("@/ui/input");
const tagsApi = await import("../../api/git-tags-api");
const { GitCreateTagDialog } = await import("./git-create-tag-dialog");
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const spies: Array<{ mockRestore: () => void }> = [];
const pendingCreations: Array<(created: boolean) => void> = [];
const createTag = mock(
  (..._args: Parameters<typeof tagsApi.createTag>) =>
    new Promise<boolean>((resolve) => pendingCreations.push(resolve)),
);
const onCreated = mock(async () => {});
const onClose = mock(() => {});
const commit: GitCommit = {
  hash: "a".repeat(40),
  shortHash: "aaaaaaa",
  parentHashes: [],
  message: "Earlier commit",
  author: "Developer",
  date: "2026/10/06 10:00",
  decorations: "",
};

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  createTag.mockClear();
  onCreated.mockClear();
  onClose.mockClear();
  // Stub shared controls so portal animation and React DOM's module-order
  // detection cannot suppress the form events; exercise the tag workflow.
  spies.push(
    spyOn(dialogs, "default").mockImplementation(({ title, children, footer, onClose }) => (
      <section role="dialog">
        <h2>{title}</h2>
        {children}
        {footer}
        <button aria-label="Close" onClick={onClose} />
      </section>
    )),
    spyOn(tagsApi, "createTag").mockImplementation(createTag),
    spyOn(inputs, "default").mockImplementation((({ value, disabled, onChange }: InputProps) => (
      <input
        value={value}
        disabled={disabled}
        onInput={(event) => onChange?.(event as unknown as ChangeEvent<HTMLInputElement>)}
      />
    )) as typeof inputs.default),
  );
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const resolve of pendingCreations.splice(0)) resolve(false);
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

const renderDialog = async (repoPath = "C:/repo-a", selected = commit) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCreateTagDialog
          key={`${repoPath}:${selected.hash}`}
          repoPath={repoPath}
          commit={selected}
          onCreated={onCreated}
          onClose={onClose}
        />
      </LocaleProvider>,
    ),
  );
};
const input = () => container.querySelector<HTMLInputElement>("input")!;
const button = (label: string) => {
  const found = Array.from(container.querySelectorAll<HTMLButtonElement>("button")).find(
    (button) => button.textContent === label,
  );
  if (!found) throw new Error(`Missing button ${label}`);
  return found;
};
const setName = async (name: string) =>
  act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input(), name);
    input().dispatchEvent(new Event("input", { bubbles: true }));
  });
const submit = async () =>
  act(async () => {
    container
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
const finishCreation = async (created: boolean) => {
  const resolve = pendingCreations.shift();
  if (!resolve) throw new Error("No pending tag creation");
  await act(async () => resolve(created));
};

test("validates names and creates a lightweight tag on the selected commit exactly once", async () => {
  await renderDialog();
  expect(container.textContent).toContain(`Create New Tag On ${commit.hash}`);
  expect(button("OK").disabled).toBe(true);
  await submit();
  await setName("bad tag");
  expect(button("OK").disabled).toBe(true);
  await submit();
  expect(createTag).not.toHaveBeenCalled();

  await setName("release/v1");
  expect(button("OK").disabled).toBe(false);
  await act(async () => {
    const form = container.querySelector("form")!;
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    container.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click();
  });
  expect(createTag.mock.calls).toEqual([["C:/repo-a", "release/v1", undefined, commit.hash, false, { lightweight: true }]]);
  expect(input().disabled).toBe(true);
  expect(onClose).not.toHaveBeenCalled();
  await finishCreation(true);
  expect(onCreated).toHaveBeenCalledTimes(1);
  expect(onClose).toHaveBeenCalledTimes(1);
});

test("cancel closes the tag dialog without writing", async () => {
  await renderDialog();
  await setName("release/cancelled");
  await act(async () => button("Cancel").click());
  expect(onClose).toHaveBeenCalledTimes(1);
  expect(createTag).not.toHaveBeenCalled();
});

test("failed creation retains the name and allows a retry before refreshing", async () => {
  await renderDialog();
  await setName("release/retry");
  await submit();
  await finishCreation(false);
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("release/retry");
  expect(input().value).toBe("release/retry");
  expect(onCreated).not.toHaveBeenCalled();
  expect(onClose).not.toHaveBeenCalled();
  await submit();
  await finishCreation(true);
  expect(createTag).toHaveBeenCalledTimes(2);
  expect(onCreated).toHaveBeenCalledTimes(1);
  expect(onClose).toHaveBeenCalledTimes(1);
});

test("late success from a previous repository cannot refresh or close the new dialog", async () => {
  await renderDialog();
  await setName("release/old-repo");
  await submit();
  const nextCommit = { ...commit, hash: "b".repeat(40), shortHash: "bbbbbbb" };
  await renderDialog("C:/repo-b", nextCommit);
  await finishCreation(true);
  expect(container.textContent).toContain(nextCommit.hash);
  expect(input().value).toBe("");
  expect(onCreated).not.toHaveBeenCalled();
  expect(onClose).not.toHaveBeenCalled();
});
