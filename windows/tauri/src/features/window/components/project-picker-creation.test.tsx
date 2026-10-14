import { afterAll, afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, useEffect, type ReactNode } from "react";
import { create } from "zustand";
import { installHappyDom } from "@/test-utils/happy-dom";

// Real ProjectPicker, Command, Base UI dismissal and wizard. Native I/O and
// unrelated visual/services are doubles. Hold host visibility acknowledgement
// explicitly: dismissal must cancel before any animation/unmount can help.
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
mock.module("@/platform/tauri-core", () => ({ invoke, convertFileSrc: (path: string) => path }));
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

mock.module("@/config/backend-capabilities", () => ({
  BACKEND_UNAVAILABLE_TOOLTIP: "",
  isBackendCapabilityAvailable: () => false,
}));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({
  useWorkspaceTabsStore: { use: { projectTabs: () => [] } },
}));
const recent = create(() => ({
  recentFolders: [],
  actions: {
    openRecentFolder: mock(() => {}),
    removeFromRecents: mock(() => {}),
    removeMissingFromRecents: mock(() => {}),
  },
}));
mock.module("@/features/file-system/stores/recent-folders.store", () => ({
  useRecentFoldersStore: recent,
}));
mock.module("@/features/remote/components/connection-form", () => ({ default: () => null }));
mock.module("@/features/remote/components/password-prompt-dialog", () => ({ default: () => null }));
mock.module("@/features/remote/services/remote-connection-actions", () => ({
  connectRemoteConnection: mock(async () => {}),
  loadRemoteConnections: async () => [],
  testRemoteConnection: mock(async () => {}),
}));
mock.module("@/features/remote/stores/remote-connection.store", () => ({ connectionStore: {} }));
mock.module("@/ui/dialog", () => ({ showPromptDialog: mock(async () => null) }));
mock.module("@/ui/scroll-area", () => ({
  ScrollArea: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}));
const { default: ProjectPicker } = await import("./project-picker");
const { MotionConfig } = await import("motion/react");
let container: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let errors: ReturnType<typeof spyOn>;
async function render(visible: boolean) {
  await act(async () =>
    root.render(
      <MotionConfig reducedMotion="never">
        <ProjectPicker isOpen={visible} initialMode="new-project" onClose={close} />
      </MotionConfig>,
    ),
  );
}
beforeEach(async () => {
  generation = deferred<string>();
  gates.push(generation);
  files.setState({ rootFolderPath: "/workspace" });
  invoke.mockClear();
  close.mockClear();
  open.mockClear();
  errors = spyOn(console, "error").mockImplementation(() => {});
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await render(true);
  await act(async () => {
    const title = [...document.querySelectorAll("span")].find(
      (element) => element.textContent === "javaProject.spring",
    );
    if (!title) throw new Error("Spring source option missing");
    title.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });
  await act(async () => {
    const input = document.querySelector<HTMLInputElement>("#new-project-name")!;
    input.value = "Demo";
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () =>
    document
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(invoke).toHaveBeenCalledTimes(1);
});
afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const gate of gates.splice(0)) gate.resolve("/projects/Demo");
    });
  } finally {
    container.remove();
    errors.mockRestore();
  }
  expect(workspaceListeners.size).toBe(0);
});
afterAll(() => {
  restoreDom();
  if (previousAct) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", previousAct);
  else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT");
});
for (const dismissal of ["escape", "backdrop"] as const) {
  for (const outcome of ["success", "failure"] as const) {
    test(`real outer ${dismissal} retires ${outcome} before the host hides or unmounts the picker`, async () => {
      await act(async () => {
        const popup = document.querySelector<HTMLElement>("[data-command-surface]")!;
        if (dismissal === "escape") {
          popup.focus();
          popup.dispatchEvent(
            new KeyboardEvent("keydown", {
              key: "Escape",
              code: "Escape",
              bubbles: true,
              cancelable: true,
            }),
          );
        } else {
          popup
            .closest(".fixed")!
            .dispatchEvent(
              new window.MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }),
            );
        }
      });
      expect(close).toHaveBeenCalledTimes(1);
      expect(document.querySelector("[data-command-surface]")).not.toBeNull();
      await act(async () =>
        outcome === "success"
          ? generation.resolve("/projects/Demo")
          : generation.reject(new Error("retired outer failure")),
      );
      expect(open).not.toHaveBeenCalled();
      expect(close).toHaveBeenCalledTimes(1);
      expect(document.body.textContent).not.toContain("retired outer failure");
      expect(errors).not.toHaveBeenCalled();
      // Complete the held host acknowledgement, without relying on wall-clock animation timing.
      await render(false);
    });
  }
}
test("a non-dismissed real picker still opens the generated project and closes once", async () => {
  await act(async () => generation.resolve("/projects/Demo"));
  expect(open).toHaveBeenCalledTimes(1);
  expect(close).toHaveBeenCalledTimes(1);
});
