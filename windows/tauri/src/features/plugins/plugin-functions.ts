import { invoke } from "@/platform/tauri-core";
import {
  PluginFunctionSession,
  type FunctionInput,
  type FunctionPorts,
  type FunctionState,
} from "./plugin-function-session";

const owners = new Set<PluginFunctionSession>();
const listeners = new Set<() => void>();
let revision = 0;
function changed() {
  revision++;
  for (const listener of listeners) listener();
}
export const pluginFunctionCleanup = {
  subscribe(listener: () => void) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
  revision: () => revision,
  pending: () =>
    [...owners].filter(
      (owner) => owner.state.phase === "cleanupFailed" || owner.state.phase === "stopping",
    ),
};

export function createPluginFunctionSession(
  input: FunctionInput,
  assertCurrent: () => void,
  publish: (state: FunctionState) => void,
) {
  const ports: FunctionPorts = {
    prepare: (value) =>
      invoke("declarative_plugins_function_prepare", value as unknown as Record<string, unknown>),
    confirm: (operationId) => invoke("declarative_plugins_function_confirm", { operationId }),
    read: (operationId) => invoke("declarative_plugins_function_state", { operationId }),
    cancel: (operationId) => invoke("declarative_plugins_function_cancel", { operationId }),
    assertCurrent,
    wait: (signal) =>
      new Promise<void>((resolve) => {
        const done = () => {
          clearTimeout(timer);
          signal.removeEventListener("abort", done);
          resolve();
        };
        const timer = setTimeout(done, 150);
        signal.addEventListener("abort", done, { once: true });
        if (signal.aborted) done();
      }),
    deadline: (expired) => {
      const timer = setTimeout(expired, 180_000);
      return () => clearTimeout(timer);
    },
  };
  return new PluginFunctionSession(input, ports, publish, (owner, retained) => {
    if (retained) owners.add(owner);
    else owners.delete(owner);
    changed();
  });
}
