import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ChangeEvent } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as core from "@/platform/tauri-core";
import type { InputProps } from "@/ui/input";
import type { GitReference } from "../../types/git.types";
import type { GitBranchNameError, GitBranchNamePreview } from "../../utils/git-branch-name";

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

interface PreviewRequest {
  rawName: string;
  requireName: boolean;
  references: Array<{ kind: GitReference["kind"]; shortName: string }>;
  reference?: { kind: GitReference["kind"]; shortName: string };
}

// The dialog only consumes Core's answer, so this double models the few names
// the interaction tests use. Cleaning and validation rules themselves are
// tested in Rust Core, not re-implemented here.
const cleanedNames: Record<string, string> = {
  "my new branch": "my-new-branch",
  "my ": "my-",
};
const branchErrors: Record<string, GitBranchNameError> = {
  main: { code: "alreadyExists", name: "main" },
  "origin/main": { code: "clashesWithRemote", name: "origin/main" },
  feature: { code: "clashesWithDirectory", name: "feature" },
  "feature/login": { code: "alreadyExists", name: "feature/login" },
};
const initialNameFor = (request: PreviewRequest["reference"]): string => {
  if (!request) return "";
  if (request.kind !== "remote") return request.shortName;
  const separator = request.shortName.indexOf("/");
  return separator < 0 ? request.shortName : request.shortName.slice(separator + 1);
};
const previewFor = (request: PreviewRequest): GitBranchNamePreview => {
  const typingCleanedName = cleanedNames[request.rawName] ?? request.rawName;
  const cleanedName = typingCleanedName.replace(/(?:[./]|\.lock)$/, "");
  const error =
    request.requireName && !request.rawName.trim()
      ? { code: "empty" as const }
      : branchErrors[request.rawName] ?? null;
  return { typingCleanedName, cleanedName, initialName: initialNameFor(request.reference), error };
};
// A gated preview stands in for a slow Core answer that must not overwrite newer input.
let gatedRawName: string | null = null;
const gates = new Map<string, (preview: GitBranchNamePreview) => void>();
const preview = mock(
  (command: string, args: PreviewRequest): Promise<GitBranchNamePreview> => {
    if (command !== "git.branchNamePreview") {
      return Promise.reject(new Error(`Unexpected command: ${command}`));
    }
    if (gatedRawName !== null && args.rawName === gatedRawName) {
      return new Promise((resolve) => gates.set(args.rawName, resolve));
    }
    return Promise.resolve(previewFor(args));
  },
);

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  createAndCheckoutBranch.mockClear();
  onCreated.mockClear();
  onClose.mockClear();
  preview.mockClear();
  gatedRawName = null;
  gates.clear();
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
    spyOn(core, "invoke").mockImplementation(preview as unknown as typeof core.invoke),
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
      for (const resolve of gates.values()) {
        resolve(previewFor({ rawName: "", requireName: false, references: [] }));
      }
      gates.clear();
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

// Every preview may chain a caret-mapping request; a few deterministic flushes
// settle the newest one without real-time waits.
const flush = async () => {
  for (let index = 0; index < 4; index += 1) {
    await act(async () => {});
  }
};
const renderDialog = async (referenceToCreateFrom: GitReference = source) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCreateBranchDialog
          repoPath="C:/repo-a"
          reference={referenceToCreateFrom}
          references={references}
          onCreated={onCreated}
          onClose={onClose}
        />
      </LocaleProvider>,
    ),
  );
  await flush();
};
const input = () => container.querySelector<HTMLInputElement>("input")!;
const button = (label: string) => {
  const found = Array.from(container.querySelectorAll<HTMLButtonElement>("button")).find(
    (candidate) => candidate.textContent === label,
  );
  if (!found) throw new Error(`Missing button ${label}`);
  return found;
};
const setInput = async (name: string, caret?: number) => {
  await act(async () => {
    const node = input();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(node, name);
    if (caret !== undefined) node.setSelectionRange(caret, caret);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await flush();
};
const submit = async () => {
  await act(async () => {
    container
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  await flush();
};
const alertText = () => container.querySelector('[role="alert"]')?.textContent ?? null;

test("matches IDEA's layout: title, Branch Name row and Create button, no checkout or overwrite options", async () => {
  await renderDialog();
  expect(container.textContent).toContain("Create Branch from origin/feature/signup");
  expect(container.textContent).toContain("Branch Name:");
  // The suggested name comes from Core (`initialName`) once the preview resolves.
  expect(input().value).toBe("feature/signup");
  // The suggested name is fully selected so a single Backspace clears it.
  expect([input().selectionStart, input().selectionEnd]).toEqual([0, "feature/signup".length]);
  expect(container.querySelectorAll('input[type="checkbox"]').length).toBe(0);
  expect(container.textContent).not.toMatch(/checkout|overwrite/i);
  expect(button("Create").disabled).toBe(false);
  expect(button("Cancel").disabled).toBe(false);
});

test("cleans typed names through Core and reports conflicts only after Create is pressed", async () => {
  await renderDialog();
  await setInput("my new branch");
  expect(input().value).toBe("my-new-branch");
  expect(alertText()).toBeNull();

  // Nothing is validated while typing before the first Create attempt.
  await setInput("main");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
  await submit();
  expect(alertText()).toBe("Branch name main already exists");
  expect(button("Create").disabled).toBe(true);
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();

  // After the first attempt the error follows the typed name.
  await setInput("origin/main");
  expect(alertText()).toBe(
    "Branch name origin/main conflicts with remote branch with the same name",
  );
  await setInput("feature");
  expect(alertText()).toBe(
    "Branch name feature conflicts with local branch directory with the same name",
  );
  await setInput("topic/free");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
});

test("keeps the caret where the user typed while Core cleans the text", async () => {
  await renderDialog();
  await setInput("my new branch", 3);
  expect(input().value).toBe("my-new-branch");
  expect(input().selectionStart).toBe(3);
});

test("a slow preview for older input cannot overwrite newer text", async () => {
  await renderDialog();
  gatedRawName = "old name";
  await setInput("old name");
  expect(input().value).toBe("old name");

  await setInput("topic/new");
  expect(input().value).toBe("topic/new");

  const resolveOld = gates.get("old name");
  expect(resolveOld).toBeDefined();
  await act(async () =>
    resolveOld!(previewFor({ rawName: "old name", requireName: false, references })),
  );
  await flush();
  expect(input().value).toBe("topic/new");
});

test("empty names are reported on apply, not while idle", async () => {
  await renderDialog();
  await setInput("");
  expect(alertText()).toBeNull();
  await submit();
  expect(alertText()).toBe("Specify name for the new branch");
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();
});

test("creates and checks out the new branch exactly once, then refreshes and closes", async () => {
  await renderDialog();
  await setInput("topic/new");
  await act(async () => {
    const form = container.querySelector("form")!;
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  await flush();
  expect(createAndCheckoutBranch.mock.calls).toEqual([["C:/repo-a", "topic/new", source]]);
  expect(input().disabled).toBe(true);
  expect(onClose).not.toHaveBeenCalled();
  await act(async () => pending.shift()!.resolve());
  expect(onCreated.mock.calls).toEqual([["topic/new"]]);
  expect(onClose).toHaveBeenCalledTimes(1);
});

test("a failed creation keeps the dialog open with the git error and allows a retry", async () => {
  await renderDialog();
  await setInput("topic/retry");
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
  await renderDialog(reference("remote", "origin/feature/login"));
  expect(input().value).toBe("feature/login");
  expect(alertText()).toBeNull();
  expect(button("Create").disabled).toBe(false);
  await submit();
  expect(alertText()).toBe("Branch name feature/login already exists");
  expect(button("Create").disabled).toBe(true);
  expect(createAndCheckoutBranch).not.toHaveBeenCalled();
});
