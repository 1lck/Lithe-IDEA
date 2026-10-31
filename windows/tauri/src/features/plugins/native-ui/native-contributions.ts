import { invoke } from "@/platform/tauri-core";
import { NativePanelStateStore } from "./native-panel-state";
import type { NativeContribution } from "./native-ui.types";

export const nativePanelStates = new NativePanelStateStore();
export { nativeViewId, openNativeContribution } from "./native-docking";
export const listNativeContributions = () =>
  invoke<NativeContribution[]>("declarative_plugins_native_windows");
