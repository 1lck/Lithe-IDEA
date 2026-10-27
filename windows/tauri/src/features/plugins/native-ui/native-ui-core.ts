import { invoke } from "@/platform/tauri-core";
import type { NativeNode, NativePanelPort, NativeUI } from "./native-ui.types";

export type NativeDataResult =
  | { status: "ok"; nodes: NativeNode[] }
  | {
      status: "rejected";
      error: { code: string; message: string };
    };
export type NativeDataOperation = (ui: NativeUI, data: unknown) => Promise<NativeDataResult>;

/** A typed adapter to the existing shared operation, never a second validator. */
export function nativeUIValidator(
  operation: NativeDataOperation = (ui, data) =>
    invoke("plugins.nativeUI.validateData", { ui, data }),
): NativePanelPort["validate"] {
  return async (ui, data, signal) => {
    signal.throwIfAborted();
    const result = await operation(ui, data);
    signal.throwIfAborted();
    if (result.status !== "ok")
      throw Object.assign(new Error("pluginNative.invalidData"), { cause: result.error });
    return result.nodes;
  };
}
