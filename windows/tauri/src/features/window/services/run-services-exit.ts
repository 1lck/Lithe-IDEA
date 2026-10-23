import { create } from "zustand";
import { executeCore } from "@/core/lithe-core-client";
import {
  listOwnedRunProcesses,
  stopOwnedRunProcesses,
  type OwnedRunProcess,
  type OwnedRunProcessScope,
} from "@/features/run/api/run-host-api";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { RunServicesOnExit } from "@/features/settings/types/settings.types";
import { frontendTrace } from "@/utils/frontend-trace";

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/** Why Run services would stop; it changes only the wording of the question. */
export type RunServicesExitPurpose = "closeWindow" | "quit" | "update";

export interface RunServicesPrompt {
  purpose: RunServicesExitPurpose;
  /** Services the user is asked about; an empty title is an unnamed service. */
  titles: string[];
  stopping: boolean;
  /** Why the last stop failed; the services it names are still running. */
  error: string | null;
}

type RunServicesAnswer = "stop" | "cancel";

interface RunServicesPromptState {
  prompt: RunServicesPrompt | null;
  owner: symbol | null;
  answer: ((answer: RunServicesAnswer) => void) | null;
}

/** The question this window shows; `WindowCloseGuard` renders it. */
export const useRunServicesPromptStore = create<RunServicesPromptState>(() => ({
  prompt: null,
  owner: null,
  answer: null,
}));

export function answerRunServicesPrompt(answer: RunServicesAnswer) {
  const resolve = useRunServicesPromptStore.getState().answer;
  useRunServicesPromptStore.setState({ answer: null });
  resolve?.(answer);
}

type LifecycleContext = "quit" | "closeWorkspace";

export interface RunServicesExitDependencies {
  list: (scope: OwnedRunProcessScope) => Promise<OwnedRunProcess[]>;
  stop: (scope: OwnedRunProcessScope) => Promise<void>;
  /** Returns the services the user must confirm before they stop. */
  servicesToConfirm: (
    services: OwnedRunProcess[],
    context: LifecycleContext,
    policy: RunServicesOnExit,
  ) => Promise<OwnedRunProcess[]>;
  policy: () => RunServicesOnExit;
}

const defaultDependencies: RunServicesExitDependencies = {
  list: listOwnedRunProcesses,
  stop: stopOwnedRunProcesses,
  servicesToConfirm: confirmRunServicesWithCore,
  policy: () => useSettingsStore.getState().settings.runServicesOnExit,
};

/**
 * Ends the Run services that leaving `scope` would end, after asking when the
 * shared Rust Core rule says so. Resolves `false` when the user keeps them by
 * cancelling, and `true` once none is left running.
 *
 * The native table is the source: it also has Maven goals and the services of
 * projects that were closed while their process kept running. Services stop
 * before the window closes or the update installs, so a tree that cannot be
 * ended is reported here instead of disappearing with the window.
 */
export async function stopRunServicesBeforeLeaving(
  scope: OwnedRunProcessScope,
  purpose: RunServicesExitPurpose,
  dependencies: RunServicesExitDependencies = defaultDependencies,
): Promise<boolean> {
  let owned: OwnedRunProcess[];
  try {
    owned = await dependencies.list(scope);
  } catch (error) {
    // Nothing can be listed, so nothing can be asked about. The host still
    // ends every owned tree when the window or Lithe goes away.
    frontendTrace("error", "run.exit", "listFailed", { error: errorMessage(error) });
    return true;
  }
  if (owned.length === 0) return true;

  const visible = owned.filter((process) => !process.background);
  const context = purpose === "closeWindow" ? "closeWorkspace" : "quit";
  const asked = await dependencies.servicesToConfirm(visible, context, dependencies.policy());
  const owner = Symbol(purpose);
  let prompt: RunServicesPrompt | null =
    asked.length > 0 ? { purpose, titles: titlesOf(asked), stopping: false, error: null } : null;
  try {
    for (;;) {
      if (prompt && (await ask(owner, prompt)) === "cancel") return false;
      show(owner, prompt && { ...prompt, stopping: true, error: null });
      try {
        await dependencies.stop(scope);
        return true;
      } catch (error) {
        prompt = {
          purpose,
          titles: prompt?.titles ?? titlesOf(visible),
          stopping: false,
          error: errorMessage(error),
        };
      }
    }
  } finally {
    if (useRunServicesPromptStore.getState().owner === owner) {
      useRunServicesPromptStore.setState({ prompt: null, owner: null, answer: null });
    }
  }
}

function ask(owner: symbol, prompt: RunServicesPrompt): Promise<RunServicesAnswer> {
  // A newer question replaces one nobody answered, which then counts as cancelled.
  answerRunServicesPrompt("cancel");
  return new Promise((resolve) => {
    useRunServicesPromptStore.setState({ prompt, owner, answer: resolve });
  });
}

function show(owner: symbol, prompt: RunServicesPrompt | null) {
  useRunServicesPromptStore.setState({ prompt, owner });
}

function titlesOf(services: OwnedRunProcess[]) {
  return services.map((service) => service.title ?? "");
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

interface LifecyclePlan {
  decisions: Array<{ id: string; action: string }>;
}

/** Asks Rust Core's `processLifecycle.resolve`, which macOS uses for the same question. */
export async function confirmRunServicesWithCore(
  services: OwnedRunProcess[],
  context: LifecycleContext,
  policy: RunServicesOnExit,
): Promise<OwnedRunProcess[]> {
  if (services.length === 0) return [];
  try {
    const response = await executeCore<LifecyclePlan>({
      id: `process-lifecycle-${crypto.randomUUID()}`,
      command: "processLifecycle.resolve",
      payload: {
        context,
        settings: { runServicesOnExit: policy },
        // Session IDs repeat across windows, so records are named by position.
        records: services.map((_, index) => ({
          id: String(index),
          kind: "run",
          ownership: "launched",
        })),
      },
    });
    if (!response.ok) throw new Error(response.error.message);
    const asked = new Set(
      response.data.decisions
        .filter((decision) => decision.action === "confirmStop")
        .map((decision) => decision.id),
    );
    return services.filter((_, index) => asked.has(String(index)));
  } catch (error) {
    // Asking is the safe answer when the shared rule cannot be reached.
    frontendTrace("error", "run.exit", "policyUnavailable", { error: errorMessage(error) });
    return services;
  }
}
