import type { createRunStore } from "@/features/run/stores/run.store";

type RunStore = Pick<ReturnType<typeof createRunStore>, "getState">;

/**
 * Binds the Run store to `root` for the Settings page without reloading a store
 * that already owns it. Opening Settings is not a reason to re-read documents:
 * a reload would wait for an in-flight identification and flash the list into
 * its loading state for no new information.
 */
export function ensureRunSettingsProject(store: RunStore, root: string): Promise<void> {
  const state = store.getState();
  if (state.root === root) return Promise.resolve();
  return state.actions.loadProject(root);
}
