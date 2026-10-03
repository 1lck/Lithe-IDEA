import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { createMemoryStateStorage } from "@/utils/zustand-storage";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
let dialog: typeof import("@/ui/dialog");
let GitChangelistBar: typeof import("./git-changelist-bar").GitChangelistBar;
import { useGitChangelistsStore, workspaceChangelists } from "../stores/git-changelists.store";

const workspace = "C:/changelist-test";
let restoreDom: () => void;
let previousStorage: PropertyDescriptor | undefined;
let root: Root;
let container: HTMLDivElement;
let confirmation: ReturnType<typeof spyOn<typeof dialog, "showConfirmDialog">>;
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousState: Pick<
  ReturnType<typeof useGitChangelistsStore.getState>,
  "workspaces" | "unavailable"
>;
let previousObserver: typeof ResizeObserver;
let restoreControls: () => void;

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: createMemoryStateStorage(),
  });
  dialog = await import("@/ui/dialog");
  ({ GitChangelistBar } = await import("./git-changelist-bar"));
  const { createRoot } = await import("react-dom/client");
  // Other files may load React/Base UI before happy-dom exists. Stub only the
  // native control boundary so module-order-dependent portal/input detection
  // cannot suppress the actual changelist handlers exercised below.
  const input = await import("@/ui/input");
  const select = await import("@/ui/select");
  const frame = spyOn(dialog, "Dialog").mockImplementation(({ open, children }) => (
    <>{open && typeof children !== "function" ? children : null}</>
  ));
  const content = spyOn(dialog, "DialogContent").mockImplementation(({ children }) => (
    <div>{children}</div>
  ));
  const title = spyOn(dialog, "DialogTitle").mockImplementation(({ children }) => (
    <h2>{children}</h2>
  ));
  const textField = spyOn(input, "default").mockImplementation((({
    onChange,
    value,
    autoFocus,
    maxLength,
    onKeyDown,
    "aria-label": label,
  }: import("@/ui/input").InputProps) => (
    <input
      value={value}
      autoFocus={autoFocus}
      maxLength={maxLength}
      onKeyDown={onKeyDown}
      aria-label={label}
      onInput={(event) => onChange?.({ ...event, target: event.currentTarget })}
    />
  )) as typeof input.default);
  const picker = spyOn(select, "default").mockImplementation(
    ({ value, options, onChange, disabled, "aria-label": label }) => (
      <select
        aria-label={label}
        value={value}
        disabled={disabled}
        onInput={(event) => onChange(event.currentTarget.value)}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    ),
  );
  restoreControls = () => {
    picker.mockRestore();
    textField.mockRestore();
    title.mockRestore();
    content.mockRestore();
    frame.mockRestore();
  };

  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  previousObserver = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  previousState = {
    workspaces: useGitChangelistsStore.getState().workspaces,
    unavailable: useGitChangelistsStore.getState().unavailable,
  };
  useGitChangelistsStore.setState({ workspaces: {}, unavailable: false });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  confirmation = spyOn(dialog, "showConfirmDialog").mockResolvedValue(false);
});
afterEach(async () => {
  await act(async () => root.unmount());
  confirmation.mockRestore();
  restoreControls();
  useGitChangelistsStore.setState(previousState);
  container.remove();
  globalThis.ResizeObserver = previousObserver;
  if (previousStorage) Object.defineProperty(globalThis, "localStorage", previousStorage);
  else Reflect.deleteProperty(globalThis, "localStorage");
  restoreDom();
  if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
  else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
});
const button = (name: string) =>
  document.querySelector<HTMLButtonElement>(`[aria-label="${name}"]`)!;
const clickText = async (text: string) => {
  const target = [...document.querySelectorAll<HTMLButtonElement>("button")].find(
    (item) => item.textContent === text,
  )!;
  expect(target).toBeDefined();
  await act(async () => target.click());
};
const nameList = async (name: string) => {
  const input = document.querySelector<HTMLInputElement>('[aria-label="Changelist name"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, name);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await clickText("Save");
};

test("the toolbar creates, selects, renames and confirms deletion of a local list", async () => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitChangelistBar workspace={workspace} disabled={false} />
      </LocaleProvider>,
    ),
  );
  expect(button("Delete changelist").disabled).toBe(true);
  await act(async () => button("New changelist").click());
  await nameList("Local only");
  expect(workspaceChangelists(useGitChangelistsStore.getState(), workspace).lists[1]?.name).toBe(
    "Local only",
  );
  const picker = document.querySelector<HTMLSelectElement>('[aria-label="Active changelist"]')!;
  await act(async () => {
    picker.value = workspaceChangelists(useGitChangelistsStore.getState(), workspace).lists[1]!.id;
    picker.dispatchEvent(new Event("input", { bubbles: true }));
  });
  expect(workspaceChangelists(useGitChangelistsStore.getState(), workspace).activeId).not.toBe(
    "default",
  );
  await act(async () => button("Rename changelist").click());
  await nameList("Configuration");
  expect(container.textContent).toContain("Configuration");
  await act(async () => button("Delete changelist").click());
  expect(workspaceChangelists(useGitChangelistsStore.getState(), workspace).lists).toHaveLength(2);
  confirmation.mockResolvedValueOnce(true);
  await act(async () => button("Delete changelist").click());
  expect(workspaceChangelists(useGitChangelistsStore.getState(), workspace).activeId).toBe(
    "default",
  );
  expect(workspaceChangelists(useGitChangelistsStore.getState(), workspace).lists).toHaveLength(1);
});
