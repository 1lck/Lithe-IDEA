import { invoke } from "@/platform/tauri-core";

/** Injectable transport only; package and lifecycle acceptance belongs to Rust. */
export const pluginCore = {
  execute<T>(command: string, payload: Record<string, unknown>): Promise<T> {
    return invoke(command, payload);
  },
};
