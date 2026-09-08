import { invoke } from "@/platform/tauri-core";
import type {
  DebugAdapterConnectionLaunch,
  DebugAdapterLaunch,
  DebugAdapterSessionInfo,
} from "../types/debugger.types";

export type DebugAdapterHostInvoke = typeof invoke;

export function createDebugAdapterHostApi(invokeCommand: DebugAdapterHostInvoke) {
  return {
    startDebugAdapterSession(launch: DebugAdapterLaunch): Promise<DebugAdapterSessionInfo> {
      return invokeCommand<DebugAdapterSessionInfo>("debug_start_session", { launch });
    },

    connectDebugAdapterSession(
      launch: DebugAdapterConnectionLaunch,
    ): Promise<DebugAdapterSessionInfo> {
      return invokeCommand<DebugAdapterSessionInfo>("debug_connect_session", { launch });
    },

    allocateJvmDebugPort(): Promise<number> {
      return invokeCommand<number>("debug_allocate_loopback_port");
    },

    waitForJvmDebugPort(port: number, timeoutMilliseconds = 30_000): Promise<void> {
      return invokeCommand<void>("debug_wait_for_port", {
        args: { port, timeoutMilliseconds },
      });
    },
  };
}

export const {
  startDebugAdapterSession,
  connectDebugAdapterSession,
  allocateJvmDebugPort,
  waitForJvmDebugPort,
} = createDebugAdapterHostApi(invoke);
