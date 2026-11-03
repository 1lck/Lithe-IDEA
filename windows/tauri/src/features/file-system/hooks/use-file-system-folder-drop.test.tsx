import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";

type Registration = { resolve: (unlisten: () => void) => void; unlisten: ReturnType<typeof mock> };
let registrations: Registration[] = [];

// Each native registration resolves only when the test releases it, so the
// test controls whether the owner unmounts before or after `listen` returns.
function onDragDropEvent() {
  return new Promise<() => void>((resolve) => {
    registrations.push({ resolve, unlisten: mock(() => {}) });
  });
}
function release(registration: Registration) {
  registration.resolve(registration.unlisten as unknown as () => void);
}

// Bun module mocks outlive this file. Keep every real export and fake the
// current handles only while this file's tests run.
let fakeHandlesActive = true;
const realWindow = await import("@tauri-apps/api/window");
const realWebview = await import("@tauri-apps/api/webview");
mock.module("@tauri-apps/api/window", () => ({
  ...realWindow,
  getCurrentWindow: (...args: Parameters<typeof realWindow.getCurrentWindow>) =>
    fakeHandlesActive ? { onDragDropEvent } : realWindow.getCurrentWindow(...args),
}));
mock.module("@tauri-apps/api/webview", () => ({
  ...realWebview,
  getCurrentWebview: (...args: Parameters<typeof realWebview.getCurrentWebview>) =>
    fakeHandlesActive ? { onDragDropEvent } : realWebview.getCurrentWebview(...args),
}));
afterAll(() => {
  fakeHandlesActive = false;
});

const { useFileSystemFolderDrop } = await import("./use-file-system-folder-drop");

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

function Probe({ revision }: { revision: number }) {
  // An inline callback is a new function on every render, as in MainLayout.
  useFileSystemFolderDrop(async () => {
    void revision;
  });
  return null;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  registrations = [];
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    container.remove();
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

test("re-rendering with a new inline callback keeps one native registration", async () => {
  await act(async () => root.render(<Probe revision={0} />));
  await act(async () => release(registrations[0]!));
  await act(async () => release(registrations[1]!));
  for (const revision of [1, 2, 3]) {
    await act(async () => root.render(<Probe revision={revision} />));
  }

  expect(registrations).toHaveLength(2);
  expect(registrations.every((registration) => registration.unlisten.mock.calls.length === 0)).toBe(
    true,
  );
});

test("unmounting before registration completes still releases the native listener", async () => {
  await act(async () => root.render(<Probe revision={0} />));
  await act(async () => root.render(null));
  await act(async () => release(registrations[0]!));

  expect(registrations).toHaveLength(1);
  expect(registrations[0]!.unlisten).toHaveBeenCalledTimes(1);
});
