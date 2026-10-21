import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ChangeEvent } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { InputProps } from "@/ui/input";
import type { GitReference } from "../../types/git.types";

const dialogs = await import("@/ui/dialog");
const inputs = await import("@/ui/input");
const branchesApi = await import("../../api/git-branches-api");
const { GitCreateBranchDialog } = await import("./git-create-branch-dialog");
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const spies: Array<{ mockRestore: () => void }> = [];
const pending: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];
const createAndCheckoutBranch = mock(
  (..._args: Parameters<typeof branchesApi.createAndCheckoutBranch>) =>
    new Promise<void>((resolve, reject) => pending.push({ resolve, reject })),
);
const onCreated = mock(async (_name: string) => {});
const onClose = mock(() => {});
const reference = (kind: GitReference["kind"], shortName: string): GitReference => ({
  fullName: kind === "remote" ? `refs/remotes/${shortName}` : `refs/heads/${shortName}`,
  shortName,
  kind,
  peelsToCommit: true,
  isCurrent: false,
});
const source = reference("remote", "origin/feature/signup");
const references = [
  reference("local", "main"),
  reference("local", "feature/login"),
  reference("remote", "origin/main"),
  source,
];

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  createAndCheckoutBranch.mockClear();
  onCreated.mockClear();
  onClose.mockClear();
  // Stub shared controls so portal animation cannot suppress form events.
  spies.push(
    spyOn(dialogs, "default").mockImplementation(({ title, children, footer, onClose }) => (
      <section role="dialog">
        <h2>{title}</h2>
        {children}
        {footer}
        <button aria-label="Close" onClick={onClose} />
      </section>
    )),
    spyOn(branchesApi, "createAndCheckoutBranch").mockImplementation(createAndCheckoutBranch),
    spyOn(inputs, "default").mockImplementation((({ value, disabled, onChange, ref }: InputProps & {
      ref?: React.Ref<HTMLInputElement>;
    }) => (
      <input
        ref={ref}
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
      for (const request of pending.splice(0)) request.resolve();
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

const renderDialog = async () => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCreateBranchDialog
          repoPath="C:/repo-a"
          reference={source}
          references={references}
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
    (candidate) => candidate.textContent === label,
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
const alertText = () => container.querySelector('[role="alert"]')?.textContent ?? null;

test("matches IDEA's layout: title, Branch Name row and Create button, no checkout or overwrite options", async () => {
  await renderDialog();
  expect(container.textContent).toContain("Create Branch from origin/feature/signup");
  expect(container.textContent).toContain("Branch Name:");
  expect(input().value).toBe("feature/signup");
  // The suggested name is fully selected so a single Backspace clears it.
  expect([input().selectionStart, input().selectionEnd]).toEqual([0, "feature/signup".length]);
  expect(container.querySelectorAll('input[type="checkbox"]').length).toBe(0);
  expect(container.textContent).not.toMatch(/checkout|overwrite/i);
  expect(button("Create").disabled).toBe(false);
  expect(button("Cancel").disabled).toBe(false);
});

test("cleans typed names and reports conflicts only after Create is pressed", async () => {
  await renderDialog();
  await setName("my new branch");
  expect(input().value).toBe("my-new-branch");
  expect(alertText()).toBeNull();

  // Nothing is validated while typing before the first Create attempt.
  await setName("main");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
  await submit();
  expect(alertText()).toBe("Branch name main already exists");
  expect(button("Create").disabled).toBe(true);
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();

  // After the first attempt the error follows the typed name.
  await setName("origin/main");
  expect(alertText()).toBe(
    "Branch name origin/main conflicts with remote branch with the same name",
  );
  await setName("feature");
  expect(alertText()).toBe(
    "Branch name feature conflicts with local branch directory with the same name",
  );
  await setName("topic/free");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
});

test("empty names are reported on apply, not while idle", async () => {
  await renderDialog();
  await setName("");
  expect(alertText()).toBeNull();
  await submit();
  expect(alertText()).toBe("Specify name for the new branch");
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();
});

test("creates and checks out the new branch exactly once, then refreshes and closes", async () => {
  await renderDialog();
  await setName("topic/new");
  await act(async () => {
    const form = container.querySelector("form")!;
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(createAndCheckoutBranch.mock.calls).toEqual([["C:/repo-a", "topic/new", source]]);
  expect(input().disabled).toBe(true);
  expect(onClose).not.toHaveBeenCalled();
  await act(async () => pending.shift()!.resolve());
  expect(onCreated.mock.calls).toEqual([["topic/new"]]);
  expect(onClose).toHaveBeenCalledTimes(1);
});

test("a failed creation keeps the dialog open with the git error and allows a retry", async () => {
  await renderDialog();
  await setName("topic/retry");
  await submit();
  await act(async () => pending.shift()!.reject(new Error("fatal: cannot lock ref")));
  expect(alertText()).toBe("fatal: cannot lock ref");
  expect(input().value).toBe("topic/retry");
  expect(onCreated).not.toHaveBeenCalled();
  expect(onClose).not.toHaveBeenCalled();
  await submit();
  await act(async () => pending.shift()!.resolve());
  expect(createAndCheckoutBranch).toHaveBeenCalledTimes(2);
  expect(onClose).toHaveBeenCalledTimes(1);
});

test("cancel closes without writing", async () => {
  await renderDialog();
  await act(async () => button("Cancel").click());
  expect(onClose).toHaveBeenCalledTimes(1);
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();
});

test("a suggested name that already exists locally is flagged only after Create", async () => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCreateBranchDialog
          repoPath="C:/repo-a"
          reference={reference("remote", "origin/feature/login")}
          references={references}
          onCreated={onCreated}
          onClose={onClose}
        />
      </LocaleProvider>,
    ),
  );
  expect(input().value).toBe("feature/login");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
  await submit();
  expect(alertText()).toBe("Branch name feature/login already exists");
  expect(button("Create").disabled).toBe(true);
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();
});
