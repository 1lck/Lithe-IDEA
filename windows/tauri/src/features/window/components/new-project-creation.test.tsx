import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, useEffect, type ReactNode } from "react";
import { create } from "zustand";
import { installHappyDom } from "@/test-utils/happy-dom";

// Exercise the real wizard's orchestration; shared visual controls and native I/O
// are doubles. This is not WebView2/Initializr network acceptance.
const restoreDom = installHappyDom();
const previousAct = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { configurable: true, value: true });
const { createRoot } = await import("react-dom/client");
let workspaceId = "first";
const workspaceListeners = new Set<() => void>();
const open = mock(async (_path: string) => true);
const files = create(() => ({ rootFolderPath: "/workspace", handleOpenFolderByPath: open }));
function switchWorkspace(root: string, id: string) {
  files.setState({ rootFolderPath: root });
  workspaceId = id;
  for (const listener of workspaceListeners) listener();
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
let generation = deferred<string>();
const gates: Array<ReturnType<typeof deferred<string>>> = [];
const exists = mock(async (_path: string) => false);
const invoke = mock(async (command: string) => {
  if (command !== "create_project_scaffold") throw new Error("unexpected native operation");
  return generation.promise;
});
const close = mock(() => {});
const spring = {
  groupId: "com.example",
  artifactId: "demo",
  packageName: "com.example",
  javaVersion: "17",
  bootVersion: "test",
  buildType: "maven-project",
  dependencies: [],
};
mock.module("@tauri-apps/api/path", () => ({ homeDir: async () => "/projects" }));
mock.module("@tauri-apps/plugin-os", () => ({ platform: () => "windows", arch: () => "x86_64" }));
mock.module("@tauri-apps/plugin-fs", () => ({ exists }));
mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: files,
}));
mock.module("@/features/workspace/runtime/workspace-runtime-registry", () => ({
  workspaceRuntimeRegistry: {
    getActiveWorkspaceId: () => workspaceId,
    subscribe: (listener: () => void) => {
      workspaceListeners.add(listener);
      return () => workspaceListeners.delete(listener);
    },
  },
}));
mock.module("@/features/file-system/controllers/file-operations", () => ({
  createNewDirectory: mock(async () => {}),
}));
mock.module("@/features/file-system/controllers/platform", () => ({
  openFolder: async () => null,
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: { getState: () => ({ actions: { openTerminalBuffer: mock(() => {}) } }) },
}));
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));
mock.module("./spring-project-fields", () => ({
  SpringProjectFields: ({ onChange }: { onChange: (value: unknown) => void }) => {
    useEffect(() => onChange(spring), [onChange]);
    return null;
  },
}));
const Box = ({ children }: { children?: ReactNode }) => <div>{children}</div>;
const NativeButton = ({ children, onClick, disabled, type, form, ...props }: any) => (
  <button
    onClick={onClick}
    disabled={disabled}
    type={type}
    form={form}
    aria-label={props["aria-label"]}
  >
    {children}
  </button>
);
const NativeInput = ({ ref, id, value, onChange, ...props }: any) => (
  <input
    ref={ref}
    id={id}
    value={value ?? ""}
    onInput={onChange}
    aria-label={props["aria-label"]}
  />
);
mock.module("@/ui/command", () => ({
  CommandHeader: ({ children, onClose }: any) => (
    <div>
      <button aria-label="dismiss wizard" onClick={onClose}>
        Close
      </button>
      {children}
    </div>
  ),
  CommandHeaderAction: NativeButton,
  CommandFooter: Box,
  CommandList: Box,
  CommandEmpty: Box,
  CommandInput: NativeInput,
  CommandItemBadge: Box,
  CommandItemRow: Box,
}));
mock.module("@/ui/input", () => ({ default: NativeInput }));
mock.module("@/ui/input-group", () => ({
  InputGroup: Box,
  InputGroupAddon: Box,
  InputGroupButton: NativeButton,
  InputGroupInput: NativeInput,
}));
mock.module("@/ui/button", () => ({ Button: NativeButton }));
mock.module("@/ui/field", () => ({
  Field: Box,
  FieldDescription: Box,
  FieldError: Box,
  FieldLabel: Box,
}));
mock.module("@/ui/card", () => ({
  Card: Box,
  CardDescription: Box,
  CardHeader: Box,
  CardTitle: Box,
}));
mock.module("@/ui/empty", () => ({ Empty: Box, EmptyDescription: Box }));
mock.module("@/ui/select", () => ({ default: () => null }));
mock.module("@/ui/spinner", () => ({ Spinner: () => <span>Preparing</span> }));
const { default: NewProjectContent } = await import("./new-project-content");
let container: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let mounted = false;
async function render(key = "first", onClose = close) {
  mounted = true;
  await act(async () =>
    root.render(
      <NewProjectContent
        key={key}
        initialSource="spring-boot"
        onBack={() => {}}
        onClose={onClose}
      />,
    ),
  );
  await act(async () => {
    const input = container.querySelector<HTMLInputElement>("#new-project-name")!;
    input.value = "Demo";
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
async function submit(twice = false) {
  await act(async () => {
    const form = container.querySelector("form")!;
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    if (twice) form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}
async function dismiss() {
  await act(async () =>
    container.querySelector<HTMLButtonElement>('button[aria-label="dismiss wizard"]')!.click(),
  );
}
beforeEach(async () => {
  workspaceId = "first";
  files.setState({ rootFolderPath: "/workspace" });
  generation = deferred<string>();
  gates.push(generation);
  exists.mockReset();
  exists.mockResolvedValue(false);
  invoke.mockClear();
  close.mockClear();
  open.mockReset();
  open.mockResolvedValue(true);
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await render();
});
afterEach(async () => {
  await act(async () => {
    if (mounted) root.unmount();
    for (const gate of gates.splice(0)) gate.resolve("/projects/Demo");
  });
  mounted = false;
  container.remove();
  expect(workspaceListeners.size).toBe(0);
});
afterAll(() => {
  restoreDom();
  if (previousAct) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", previousAct);
  else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT");
});

test("one live creation opens once even when its own open changes the workspace", async () => {
  open.mockImplementation(async (path) => {
    switchWorkspace(path, "created");
    return true;
  });
  await submit(true);
  expect(invoke).toHaveBeenCalledTimes(1);
  await act(async () => generation.resolve("/projects/Demo"));
  expect(open).toHaveBeenCalledTimes(1);
  expect(close).toHaveBeenCalledTimes(1);
});
for (const outcome of ["success", "failure"] as const) {
  test(`closed generation ${outcome} cannot affect a newly opened wizard`, async () => {
    await submit();
    const old = generation;
    await dismiss();
    const newClose = mock(() => {});
    await render("replacement", newClose);
    await act(async () =>
      outcome === "success"
        ? old.resolve("/projects/Demo")
        : old.reject(new Error("retired failure")),
    );
    expect(open).not.toHaveBeenCalled();
    expect(close).toHaveBeenCalledTimes(1);
    expect(newClose).not.toHaveBeenCalled();
    expect(container.querySelector("form")).not.toBeNull();
    expect(container.textContent).not.toContain("retired failure");
  });
  test(`unmounted generation ${outcome} has no completion side effects`, async () => {
    await submit();
    await act(async () => {
      root.unmount();
      mounted = false;
    });
    await act(async () =>
      outcome === "success"
        ? generation.resolve("/projects/Demo")
        : generation.reject(new Error("retired failure")),
    );
    expect(open).not.toHaveBeenCalled();
    expect(close).not.toHaveBeenCalled();
  });
}
test("switching away and back retires the old generation without releasing a newer request", async () => {
  await submit();
  const old = generation;
  await act(async () => {
    switchWorkspace("/other", "other");
    switchWorkspace("/workspace", "first");
  });
  generation = deferred<string>();
  gates.push(generation);
  await submit();
  await act(async () => old.resolve("/projects/Demo"));
  expect(open).not.toHaveBeenCalled();
  expect(invoke).toHaveBeenCalledTimes(2);
  expect(container.querySelector("form")).toBeNull();
  await act(async () => generation.resolve("/projects/Demo"));
  expect(open).toHaveBeenCalledTimes(1);
  expect(close).toHaveBeenCalledTimes(1);
});
test("closing during the existence check does not dispatch native creation", async () => {
  const check = deferred<boolean>();
  exists.mockImplementation(() => check.promise);
  try {
    await submit();
    await dismiss();
    await act(async () => check.resolve(false));
    expect(invoke).not.toHaveBeenCalled();
    expect(open).not.toHaveBeenCalled();
  } finally {
    await act(async () => check.resolve(false));
  }
});
test("closing after open was dispatched prevents its late completion from closing UI again", async () => {
  const opening = deferred<boolean>();
  open.mockImplementation(() => opening.promise);
  try {
    await submit();
    await act(async () => generation.resolve("/projects/Demo"));
    expect(open).toHaveBeenCalledTimes(1);
    await dismiss();
    await act(async () => opening.resolve(true));
    expect(close).toHaveBeenCalledTimes(1);
  } finally {
    await act(async () => opening.resolve(true));
  }
});
