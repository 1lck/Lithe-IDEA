import { beforeEach, expect, mock, test } from "bun:test";
import type { ReactElement } from "react";

const currentWindow = {
  minimize: mock(async () => undefined),
  maximize: mock(async () => undefined),
  unmaximize: mock(async () => undefined),
  isMaximized: mock(async () => false),
  isFullscreen: mock(async () => false),
  setFullscreen: mock(async () => undefined),
};

const { CopyIcon, ArrowsInIcon, ArrowsOutIcon, SquareIcon } = await import("@/ui/icons");
const { createWindowActions } = await import("./window-actions");
const {
  maximizeCurrentWindow,
  minimizeCurrentWindow,
  readWindowPresentationState,
  toggleCurrentWindowFullscreen,
  toggleCurrentWindowMaximize,
} = await import("@/features/window/utils/window-actions");

const operations = {
  minimize: mock(async () => undefined),
  toggleMaximize: mock(async () => undefined),
  toggleFullscreen: mock(async () => undefined),
};

function findAction(actions: ReturnType<typeof createWindowActions>, id: string) {
  const action = actions.find((candidate) => candidate.id === id);
  expect(action).toBeDefined();
  return action!;
}

beforeEach(() => {
  Object.values(currentWindow).forEach((operation) => operation.mockClear());
  Object.values(operations).forEach((operation) => operation.mockClear());
  currentWindow.isMaximized.mockResolvedValue(false);
  currentWindow.isFullscreen.mockResolvedValue(false);
});

test("window commands invoke Tauri window operations and close after success", async () => {
  const onClose = mock(() => undefined);
  const actions = createWindowActions({
    onClose,
    isMaximized: false,
    isFullscreen: false,
    operations,
  });
  const maximize = findAction(actions, "window-maximize");
  const enterFullscreen = findAction(actions, "window-enter-fullscreen");

  expect((maximize.icon as ReactElement).type).toBe(SquareIcon);
  expect((enterFullscreen.icon as ReactElement).type).toBe(ArrowsOutIcon);

  await findAction(actions, "window-minimize").action();
  await maximize.action();
  await enterFullscreen.action();

  expect(operations.minimize).toHaveBeenCalledTimes(1);
  expect(operations.toggleMaximize).toHaveBeenCalledTimes(1);
  expect(operations.toggleFullscreen).toHaveBeenCalledTimes(1);
  expect(onClose).toHaveBeenCalledTimes(3);
});

test("window command labels and icons reflect restore and exit-fullscreen states", () => {
  const actions = createWindowActions({
    onClose: mock(() => undefined),
    isMaximized: true,
    isFullscreen: true,
    operations,
  });
  const restore = findAction(actions, "window-restore");
  const exitFullscreen = findAction(actions, "window-exit-fullscreen");

  expect(restore.label).toBe("Window: Restore");
  expect((restore.icon as ReactElement).type).toBe(CopyIcon);
  expect(exitFullscreen.label).toBe("Window: Exit Fullscreen");
  expect((exitFullscreen.icon as ReactElement).type).toBe(ArrowsInIcon);
});

test("restore and fullscreen commands use the current native window state", async () => {
  currentWindow.isMaximized.mockResolvedValue(true);
  currentWindow.isFullscreen.mockResolvedValue(true);
  const actions = createWindowActions({
    onClose: mock(() => undefined),
    isMaximized: true,
    isFullscreen: true,
    operations: {
      minimize: () => minimizeCurrentWindow(currentWindow),
      toggleMaximize: () => toggleCurrentWindowMaximize(currentWindow),
      toggleFullscreen: () => toggleCurrentWindowFullscreen(currentWindow),
    },
  });

  await minimizeCurrentWindow(currentWindow);
  await maximizeCurrentWindow(currentWindow);
  await findAction(actions, "window-restore").action();
  await findAction(actions, "window-exit-fullscreen").action();

  expect(currentWindow.minimize).toHaveBeenCalledTimes(1);
  expect(currentWindow.maximize).toHaveBeenCalledTimes(1);
  expect(currentWindow.unmaximize).toHaveBeenCalledTimes(1);
  expect(currentWindow.setFullscreen).toHaveBeenCalledWith(false);
});

test("window state reads are delegated to the active Tauri window", async () => {
  currentWindow.isMaximized.mockResolvedValue(true);
  currentWindow.isFullscreen.mockResolvedValue(false);

  await expect(readWindowPresentationState(currentWindow)).resolves.toEqual({
    isMaximized: true,
    isFullscreen: false,
  });

  expect(currentWindow.isMaximized).toHaveBeenCalledTimes(1);
  expect(currentWindow.isFullscreen).toHaveBeenCalledTimes(1);
});
