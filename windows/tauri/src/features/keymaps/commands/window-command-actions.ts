import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createAppWindow } from "@/features/window/utils/create-app-window";
import {
  maximizeCurrentWindow,
  minimizeCurrentWindow,
  toggleCurrentWindowFullscreen,
} from "@/features/window/utils/window-actions";
import { isLinux, isMac } from "@/utils/platform";

export function toggleFullscreen(): void {
  void toggleCurrentWindowFullscreen().catch((error: unknown) =>
    console.error("Error toggling fullscreen:", error),
  );
}

export function toggleFullscreenMac(): void {
  if (isMac()) {
    toggleFullscreen();
  }
}

export function createNewWindow(): void {
  void createAppWindow();
}

export function minimizeWindow(): void {
  void minimizeCurrentWindow().catch((error: unknown) =>
    console.error("Error minimizing window:", error),
  );
}

export function minimizeWindowMac(): void {
  if (isMac()) {
    minimizeWindow();
  }
}

export function minimizeWindowAlt(): void {
  if (!isMac()) {
    minimizeWindow();
  }
}

export function maximizeWindow(): void {
  if (!isMac()) {
    void maximizeCurrentWindow().catch((error: unknown) =>
      console.error("Error maximizing window:", error),
    );
  }
}

export async function quitApplication(): Promise<void> {
  if (!isMac()) return;

  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().close();
}

export async function toggleNativeMenuBar(): Promise<void> {
  if (isMac() || isLinux()) return;

  const { settings } = useSettingsStore.getState();
  if (!settings.nativeMenuBar) return;

  const { invoke } = await import("@/platform/tauri-core");
  invoke("toggle_menu_bar").catch(console.error);
}
