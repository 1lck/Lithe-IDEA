import { getCurrentWindow, type Window } from "@tauri-apps/api/window";

export interface WindowPresentationState {
  isMaximized: boolean;
  isFullscreen: boolean;
}

export type WindowActionTarget = Pick<
  Window,
  "minimize" | "maximize" | "unmaximize" | "isMaximized" | "isFullscreen" | "setFullscreen"
>;

export async function readWindowPresentationState(
  window: WindowActionTarget = getCurrentWindow(),
): Promise<WindowPresentationState> {
  const [isMaximized, isFullscreen] = await Promise.all([
    window.isMaximized(),
    window.isFullscreen(),
  ]);

  return { isMaximized, isFullscreen };
}

export async function minimizeCurrentWindow(
  window: WindowActionTarget = getCurrentWindow(),
): Promise<void> {
  await window.minimize();
}

export async function maximizeCurrentWindow(
  window: WindowActionTarget = getCurrentWindow(),
): Promise<void> {
  await window.maximize();
}

export async function toggleCurrentWindowMaximize(
  window: WindowActionTarget = getCurrentWindow(),
): Promise<void> {
  const isMaximized = await window.isMaximized();

  if (isMaximized) {
    await window.unmaximize();
  } else {
    await window.maximize();
  }
}

export async function toggleCurrentWindowFullscreen(
  window: WindowActionTarget = getCurrentWindow(),
): Promise<void> {
  const isFullscreen = await window.isFullscreen();
  await window.setFullscreen(!isFullscreen);
}
