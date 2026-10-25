/**
 * The one Agent connection a window owns.
 *
 * A Windows window is bound to one project, so the connection is a module
 * singleton rather than per-component state: hiding the panel keeps the running
 * turn alive, switching projects stops the old process tree, and the Tauri host
 * releases anything left when the window is destroyed.
 *
 * Launch problems are turned into the panel's own message here, so the failure
 * the user reads is the reason (missing provider, stopped feature) instead of a
 * transport error.
 */

import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { resolveAppDataDirectory } from "@/platform/app-data-directory";
import { createTranslator } from "@/i18n/locale";
import { AgentLaunchError, loadAgentLaunch, settingsWithLinkedAgentProvider, type AgentLaunchFailure } from "../services/agent-launch";
import { createTauriAgentTransport } from "../services/agent-transport";
import type { AgentPanelSettings } from "../types/agent-settings.types";
import {
  AgentConnectionModel,
  type AgentConnectionSnapshot,
} from "./agent-connection.model";

import { agentDraftKey, useAgentSurfaceStore } from "./agent-surface.store";
import { readAgentStatistics, writeAgentStatistics } from "@/platform/agent-statistics-storage";

let model: AgentConnectionModel | null = null;
let connectionAgentID: string | null = null;
let workspacePath: string | null = null;
let dataDirectory: Promise<string> | null = null;
/** Opening and closing share one queue, including requests arriving during startup. */
let requestQueue: Promise<void> = Promise.resolve();
let requestGeneration = 0;
let pendingLaunchRequest: { key: string; operation: Promise<AgentPanelSettings | null> } | null = null;

function enqueueConnectionRequest<T>(operation: () => Promise<T>): Promise<T> {
  const pending = requestQueue.then(operation);
  requestQueue = pending.then(() => undefined, () => undefined);
  return pending;
}

function translator() {
  return createTranslator(useSettingsStore.getState().settings.displayLanguage);
}

/** Platform data root that also holds Lithe-managed adapter installs. */
export function agentDataDirectory(): Promise<string> {
  dataDirectory ??= resolveAppDataDirectory();
  return dataDirectory;
}

/** The panel's connection; created on first use so nothing starts at boot. */
export function agentConnection(): AgentConnectionModel {
  model ??= new AgentConnectionModel(createTauriAgentTransport(), undefined, undefined, (sessionID) => {
    if (connectionAgentID === null) return;
    useAgentSurfaceStore.getState().actions.moveDraft(
      agentDraftKey(connectionAgentID, null), agentDraftKey(connectionAgentID, sessionID),
    );
  }, {
    read: (sessionID) => workspacePath && connectionAgentID ? readAgentStatistics(workspacePath, connectionAgentID, sessionID) : null,
    write: (sessionID, statistics) => {
      if (workspacePath && connectionAgentID) writeAgentStatistics(workspacePath, connectionAgentID, sessionID, statistics);
    },
  });
  return model;
}

export function agentWorkspacePath(): string | null {
  return workspacePath;
}

const LAUNCH_FAILURE_KEYS: Record<AgentLaunchFailure, string> = {
  invalidCliConfiguration: "agent.setup.invalidCliConfiguration",
  disabled: "agent.setup.disabled",
  noAgent: "agent.setup.noAgent",
  missingProvider: "agent.setup.missingProvider",
  missingApiKey: "agent.setup.missingApiKey",
  missingCommand: "agent.setup.missingCommand",
  subscriptionNeedsCodex: "agent.setup.subscriptionNeedsCodex",
};

/**
 * The process serves one project, Agent and authentication mode; another
 * combination must not keep routing messages through the old connection.
 */
function launchKey(workspace: string, settings: AgentPanelSettings): string {
  return [
    workspace,
    settings.agentId,
    settings.authentication,
    settings.command,
    settings.arguments,
    settings.provider.id ?? "legacy",
    settings.provider.source ?? "manual",
    // Linked metadata comes from one fresh CLI snapshot, not the display cache.
    settings.provider.source ? "linked" : settings.provider.protocol,
    settings.provider.source ? "linked" : settings.provider.baseUrl,
    settings.provider.source ? "linked" : settings.provider.model,
    settings.provider.name,
    String(settings.provider.allowInsecureHttp),
    String(settings.observeModelCalls ?? true),
  ].join("\u0000");
}

let activeLaunchKey: string | null = null;

/** True only after this workspace and launch have acquired the live connection. */
export function agentConnectionMatches(
  workspace: string | null,
  settings: AgentPanelSettings,
): boolean {
  return workspace !== null && model !== null && workspacePath === workspace &&
    activeLaunchKey === launchKey(workspace, settings) && model.hasActiveConnection;
}

/** Sessions kept per Agent, so switching back shows the same conversation. */
const keptSnapshots = new Map<string, AgentConnectionSnapshot>();

/** Menu discovery reads cached summaries and never launches an Agent. */
export function cachedAgentSessions(workspace: string, settings: AgentPanelSettings) {
  const key = launchKey(workspace, settings);
  return (key === activeLaunchKey ? model?.getSnapshot() : keptSnapshots.get(key))?.sessions ?? [];
}

/**
 * Start the agent for `nextWorkspacePath`, or report why it cannot start. A
 * second call with the same project, Agent and authentication is a no-op.
 * Return this launch's effective settings, including its own linked metadata
 * commit; null means the request failed or lost ownership.
 */
export async function openAgentConnection(
  nextWorkspacePath: string,
  settings: AgentPanelSettings,
): Promise<AgentPanelSettings | null> {
  const key = launchKey(nextWorkspacePath, settings);
  // The editor and sidebar may claim the same startup together. Both must
  // observe its completed ownership instead of superseding each other.
  if (pendingLaunchRequest?.key === key) return pendingLaunchRequest.operation;
  const generation = ++requestGeneration;
  const queued = enqueueConnectionRequest(async () => {
    if (generation !== requestGeneration) return null;
    return openAgentConnectionNow(generation, key, nextWorkspacePath, settings);
  });
  const operation = queued.finally(() => {
    if (pendingLaunchRequest?.operation === operation) pendingLaunchRequest = null;
  });
  pendingLaunchRequest = { key, operation };
  return operation;
}

async function openAgentConnectionNow(
  generation: number,
  key: string,
  nextWorkspacePath: string,
  settings: AgentPanelSettings,
): Promise<AgentPanelSettings | null> {
  const connection = agentConnection();
  if (workspacePath !== nextWorkspacePath) {
    useAgentSurfaceStore.getState().actions.reset();
    // A different project starts from nothing; kept Agent sessions belong to
    // the previous workspace and must not leak into this one.
    await connection.stop();
    if (generation !== requestGeneration) return null;
    connection.reset();
    keptSnapshots.clear();
    workspacePath = nextWorkspacePath;
    activeLaunchKey = null;
  } else if (activeLaunchKey !== null && activeLaunchKey !== key) {
    keptSnapshots.set(activeLaunchKey, connection.captureSnapshot());
    await connection.stop();
    if (generation !== requestGeneration) return null;
    connection.reset();
    const kept = keptSnapshots.get(key);
    if (kept !== undefined) connection.restoreSnapshot(kept);
    activeLaunchKey = null;
  }
  if (activeLaunchKey === key && connection.hasActiveConnection) return settings;
  try {
    const launch = await loadAgentLaunch({
      workspacePath: nextWorkspacePath,
      dataDirectory: await agentDataDirectory(),
      settings,
    });
    if (generation !== requestGeneration) return null;
    connectionAgentID = settings.agentId;
    await connection.connect(launch);
    if (generation !== requestGeneration) {
      // Close a superseded process before another launch can claim its identity.
      await connection.stop();
      activeLaunchKey = null;
      return null;
    }
    activeLaunchKey = key;
    const refreshed = settingsWithLinkedAgentProvider(settings, launch);
    let effective = settings;
    if (refreshed !== settings) {
      try {
        effective = await useSettingsStore.getState().actions.commitAgentProvider(settings, refreshed);
      } catch {
        // The settings action publishes the current revision and an actionable error.
        console.warn("Linked Agent metadata could not be saved.");
        return null;
      }
    }
    return generation === requestGeneration && activeLaunchKey === key && connection.hasActiveConnection ? effective : null;
  } catch (error) {
    if (error instanceof AgentLaunchError) {
      if (generation === requestGeneration) {
        connection.reportConnectionFailure(translator()(LAUNCH_FAILURE_KEYS[error.failure]));
      }
      return null;
    }
    throw error;
  }
}

/** Stop the agent and wait for its process tree to exit. */
export async function closeAgentConnection(): Promise<void> {
  pendingLaunchRequest = null;
  requestGeneration += 1;
  return enqueueConnectionRequest(async () => {
    if (model === null) return;
    activeLaunchKey = null;
    await model.stop();
  });
}
