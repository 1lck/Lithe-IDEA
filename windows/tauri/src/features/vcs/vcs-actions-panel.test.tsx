import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { actionFixture, flushActions } from "./vcs-action-test-fixture";
import { createTranslator } from "@/i18n/locale";
const t = createTranslator("en-US");
// Proposed catalog entries belong to the integration lane. Inject them here
// to exercise the real confirmation component without editing shared i18n.
const fileOperationCopy: Record<string, string> = {
  "vcs.actions.add": "Add selected files to version control",
  "vcs.actions.delete": "Delete selected files through version control",
  "vcs.actions.risk.add":
    "Only existing ordinary files directly in this root can be added. Directories and implicit parent additions are refused.",
  "vcs.actions.risk.delete":
    "This requests deletion of every listed working file, including both rename or copy endpoints. The provider controls disk deletion; no keep-local option is sent and Lithe keeps no backup. Review file contents before continuing.",
};
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({
    t: (key: string, values?: Record<string, string | number>) =>
      fileOperationCopy[key] ?? t(key, values),
  }),
  LocaleProvider: ({ children }: { children: ReactNode }) => children,
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: (select: (state: { settings: { displayLanguage: "en-US" } }) => unknown) =>
    select({ settings: { displayLanguage: "en-US" } }),
}));
mock.module("@/ui/button", () => ({
  Button: (p: { disabled?: boolean; onClick(): void; children: ReactNode }) => (
    <button disabled={p.disabled} onClick={p.onClick}>
      {p.children}
    </button>
  ),
}));
mock.module("@/ui/checkbox", () => ({
  Checkbox: (p: {
    checked: boolean;
    disabled: boolean;
    "aria-label": string;
    onCheckedChange(checked: boolean): void;
  }) => (
    <input
      type="checkbox"
      aria-label={p["aria-label"]}
      checked={p.checked}
      disabled={p.disabled}
      onChange={(e) => p.onCheckedChange(e.target.checked)}
    />
  ),
}));
mock.module("@/ui/textarea", () => ({
  default: (p: {
    value: string;
    disabled: boolean;
    "aria-label": string;
    onChange(e: React.ChangeEvent<HTMLTextAreaElement>): void;
  }) => <textarea {...p} />,
}));
mock.module("@/ui/dialog", () => ({
  default: (p: { title: ReactNode; children: ReactNode; footer: ReactNode; onClose(): void }) => (
    <div role="dialog" aria-label={String(p.title)}>
      {p.children}
      {p.footer}
    </div>
  ),
}));
const restore = installHappyDom();
const actGlobal = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean;
};
const previous = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
const { createRoot } = await import("react-dom/client");
const { LocaleProvider } = await import("@/i18n/locale-provider");
const { VcsActionsPanel } = await import("./vcs-actions-panel");
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await act(cleanup);
});
afterAll(() => {
  if (previous === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previous;
  restore();
});
async function fixture(configure?: (f: Awaited<ReturnType<typeof actionFixture>>) => void) {
  const f = await actionFixture();
  cleanups.push(f.close);
  configure?.(f);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  cleanups.push(() => {
    root.unmount();
    container.remove();
  });
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <VcsActionsPanel
          controller={f.controller}
          root={f.view.detection.roots[0]!}
          snapshot={f.controller.status.getSnapshot().snapshot}
          readBusy={false}
        />
      </LocaleProvider>,
    ),
  );
  const button = (text: string) =>
    [...container.querySelectorAll("button")].find((button) => button.textContent === text)!;
  return { ...f, container, button };
}
test("revert confirmation shows root, both rename endpoints, count and risk; cancel stays inert", async () => {
  const f = await fixture();
  await act(async () =>
    (f.container.querySelector('input[aria-label="after.txt"]') as HTMLInputElement).click(),
  );
  await act(async () => f.button("Revert selected changes").click());
  const dialog = f.container.querySelector('[role="dialog"]')!;
  for (const text of [
    "C:/fixture/workspace",
    "2 paths affected",
    "before.txt",
    "after.txt",
    "cannot be undone",
  ])
    expect(dialog.textContent).toContain(text);
  expect(f.calls).toEqual([]);
  await act(async () => f.button("Cancel").click());
  expect(f.container.querySelector('[role="dialog"]')).toBeNull();
  expect(f.calls).toEqual([]);
});
test("commit confirmation freezes message and labels direct server commit from capabilities", async () => {
  const f = await fixture();
  expect(f.button("Commit selected changes to server")).toBeDefined();
  await act(async () =>
    f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
      operation: "checkin",
      paths: ["new.txt", "gone.txt"],
      message: "Exact message\n第二行",
    }),
  );
  const dialog = f.container.querySelector('[role="dialog"]')!;
  expect(dialog.querySelector("pre")?.textContent).toBe("Exact message\n第二行");
  for (const text of ["new.txt", "gone.txt", "directly to the server"])
    expect(dialog.textContent).toContain(text);
  await act(async () => f.button("Confirm and run").click());
  await act(flushActions);
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
});
test("update confirmation describes whole root and invalidation removes pending confirmation", async () => {
  const f = await fixture();
  await act(async () => f.button("Update working copy").click());
  expect(f.container.querySelector('[role="dialog"]')?.textContent).toContain(
    "including clean files",
  );
  await act(async () => f.controller.invalidate());
  expect(f.container.querySelector('[role="dialog"]')).toBeNull();
  expect(f.calls).toEqual([]);
});

test("resolve confirmation lists every conflict endpoint and cleanup confirms the whole root", async () => {
  const f = await fixture((f) => {
    const snapshot = f.controller.status.getSnapshot().snapshot!;
    snapshot.capabilities = {
      ...snapshot.capabilities,
      conflicts: 1,
      cleanup: 1,
    };
    snapshot.result.changes.push(
      { path: "conflict.txt", oldPath: null, status: "conflicted", flags: [] },
      {
        path: "tree.txt",
        oldPath: null,
        status: "modified",
        flags: ["treeConflict"],
      },
    );
  });
  expect(f.button(t("vcs.actions.resolve")).disabled).toBe(true);
  for (const path of ["conflict.txt", "tree.txt"])
    await act(async () =>
      (f.container.querySelector(`input[aria-label="${path}"]`) as HTMLInputElement).click(),
    );
  await act(async () => f.button(t("vcs.actions.resolve")).click());
  let dialog = f.container.querySelector('[role="dialog"]')!;
  for (const text of [
    "C:/fixture/workspace",
    "2 paths affected",
    "conflict.txt",
    "tree.txt",
    t("vcs.actions.risk.resolve"),
  ])
    expect(dialog.textContent).toContain(text);
  expect(f.calls).toEqual([]);
  await act(async () => f.button("Cancel").click());
  await act(async () => f.button(t("vcs.actions.cleanup")).click());
  dialog = f.container.querySelector('[role="dialog"]')!;
  for (const text of [
    "C:/fixture/workspace",
    "Entire working copy (all files)",
    t("vcs.actions.risk.cleanup"),
  ])
    expect(dialog.textContent).toContain(text);
  await act(async () => f.button("Confirm and run").click());
  await act(flushActions);
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
  expect(f.calls[0]?.action).toEqual({ operation: "cleanup" });
});

test("resolve and cleanup entry points follow negotiated capabilities and native root scope", async () => {
  const unsupported = await fixture();
  expect(unsupported.button(t("vcs.actions.resolve"))).toBeUndefined();
  expect(unsupported.button(t("vcs.actions.cleanup"))).toBeUndefined();
  const f = await fixture((f) => {
    const snapshot = f.controller.status.getSnapshot().snapshot!;
    snapshot.capabilities = {
      ...snapshot.capabilities,
      conflicts: 1,
      cleanup: 1,
    };
    f.view.detection.roots.push({
      id: "nested",
      path: `${f.scope.workspaceRoot}/nested`,
      vcs: "git",
      mapped: false,
    });
  });
  expect(f.button(t("vcs.actions.cleanup")).disabled).toBe(true);
  await act(async () =>
    (f.container.querySelector('input[aria-label="new.txt"]') as HTMLInputElement).click(),
  );
  expect(f.button(t("vcs.actions.resolve")).disabled).toBe(true);
  expect(f.calls).toEqual([]);
});

test("add confirmation names the root and exact files and cancel never dispatches", async () => {
  const f = await fixture((f) => {
    f.controller.status.getSnapshot().snapshot!.capabilities!.fileOperations = 1;
  });
  expect(f.button(fileOperationCopy["vcs.actions.add"]!).disabled).toBe(true);
  await act(async () =>
    (f.container.querySelector('input[aria-label="untracked.txt"]') as HTMLInputElement).click(),
  );
  expect(f.button(fileOperationCopy["vcs.actions.delete"]!).disabled).toBe(true);
  await act(async () => f.button(fileOperationCopy["vcs.actions.add"]!).click());
  const dialog = f.container.querySelector('[role="dialog"]')!;
  for (const text of [
    "C:/fixture/workspace",
    "1 paths affected",
    "untracked.txt",
    "implicit parent additions are refused",
  ])
    expect(dialog.textContent).toContain(text);
  expect(f.calls).toEqual([]);
  await act(async () => f.button("Cancel").click());
  expect(f.calls).toEqual([]);
});

test("delete confirmation exposes local file deletion and all rename endpoints before one dispatch", async () => {
  const f = await fixture((f) => {
    f.controller.status.getSnapshot().snapshot!.capabilities!.fileOperations = 1;
  });
  await act(async () =>
    (f.container.querySelector('input[aria-label="after.txt"]') as HTMLInputElement).click(),
  );
  expect(f.button(fileOperationCopy["vcs.actions.add"]!).disabled).toBe(true);
  await act(async () => f.button(fileOperationCopy["vcs.actions.delete"]!).click());
  const dialog = f.container.querySelector('[role="dialog"]')!;
  for (const text of [
    "C:/fixture/workspace",
    "2 paths affected",
    "before.txt",
    "after.txt",
    "deletion of every listed working file",
    "no keep-local option",
    "no backup",
  ])
    expect(dialog.textContent).toContain(text);
  expect(f.calls).toEqual([]);
  await act(async () => {
    f.button("Confirm and run").click();
    f.button("Confirm and run")?.click();
  });
  await act(flushActions);
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
  expect(f.calls[0]?.action).toEqual({ operation: "delete", paths: ["after.txt"] });
});

test("add and delete entries stay absent without fileOperations negotiation", async () => {
  const f = await fixture();
  expect(f.button(fileOperationCopy["vcs.actions.add"]!)).toBeUndefined();
  expect(f.button(fileOperationCopy["vcs.actions.delete"]!)).toBeUndefined();
  expect(f.calls).toEqual([]);
});
