import type { createRunStore } from "@/features/run/stores/run.store";

type RunStore = Pick<ReturnType<typeof createRunStore>, "getState">;

/**
 * Binds the Run store to `root` for the Settings page without reloading a store
 * that already owns it. A same-root reload would cancel an in-flight
 * identification, the pending refresh after JDT prepares the project, and any
 * launch still waiting for a build-failure decision.
 */
export function ensureRunSettingsProject(store: RunStore, root: string): Promise<void> {
  const state = store.getState();
  if (state.root === root) return Promise.resolve();
  return state.actions.loadProject(root);
}
