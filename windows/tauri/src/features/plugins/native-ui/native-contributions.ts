import { invoke } from "@/platform/tauri-core";
import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { NativePanelStateStore } from "./native-panel-state";
import type { NativeContribution } from "./native-ui.types";

export const nativePanelStates = new NativePanelStateStore();
export const nativeViewId = (entry: NativeContribution) =>
  `plugin-native:${encodeURIComponent(entry.pluginId)}/${encodeURIComponent(entry.windowId)}`;
export const listNativeContributions = () =>
  invoke<NativeContribution[]>("declarative_plugins_native_windows");
export function openNativeContribution(entry: NativeContribution): void {
  applyRightToolWindowIntent(nativeViewId(entry), "toggle");
}
