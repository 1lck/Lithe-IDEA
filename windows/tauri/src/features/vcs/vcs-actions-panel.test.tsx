import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { actionFixture, flushActions } from "./vcs-action-test-fixture";
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
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previous = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
const { createRoot } = await import("react-dom/client");
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
async function fixture() {
  const f = await actionFixture();
  cleanups.push(f.close);
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
