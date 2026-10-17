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
import { AgentLaunchError, loadAgentLaunch, type AgentLaunchFailure } from "../services/agent-launch";
import { createTauriAgentTransport } from "../services/agent-transport";
import type { AgentPanelSettings } from "../types/agent-settings.types";
import {
  AgentConnectionModel,
  type AgentConnectionSnapshot,
} from "./agent-connection.model";
import { useAgentSurfaceStore } from "./agent-surface.store";

let model: AgentConnectionModel | null = null;
let workspacePath: string | null = null;
let dataDirectory: Promise<string> | null = null;

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
  model ??= new AgentConnectionModel(createTauriAgentTransport());
  return model;
}

export function agentWorkspacePath(): string | null {
  return workspacePath;
}

const LAUNCH_FAILURE_KEYS: Record<AgentLaunchFailure, string> = {
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
  ].join("\u0000");
}

let activeLaunchKey: string | null = null;

/** Sessions kept per Agent, so switching back shows the same conversation. */
const keptSnapshots = new Map<string, AgentConnectionSnapshot>();

/**
 * Start the agent for `nextWorkspacePath`, or report why it cannot start. A
 * second call with the same project, Agent and authentication is a no-op.
 */
export async function openAgentConnection(
  nextWorkspacePath: string,
  settings: AgentPanelSettings,
): Promise<void> {
  const connection = agentConnection();
  const key = launchKey(nextWorkspacePath, settings);
  if (workspacePath !== nextWorkspacePath) {
    // A different project starts from nothing; kept Agent sessions belong to
    // the previous workspace and must not leak into this one. Placement state
    // is keyed by session but lives window-wide, so clear it before reconnecting.
    useAgentSurfaceStore.getState().actions.reset();
    await connection.stop();
    connection.reset();
    keptSnapshots.clear();
    workspacePath = nextWorkspacePath;
    activeLaunchKey = null;
  } else if (activeLaunchKey !== null && activeLaunchKey !== key) {
    keptSnapshots.set(activeLaunchKey, connection.captureSnapshot());
    await connection.stop();
    connection.reset();
    const kept = keptSnapshots.get(key);
    if (kept !== undefined) connection.restoreSnapshot(kept);
    activeLaunchKey = null;
  }
  if (activeLaunchKey === key && connection.hasActiveConnection) return;
  try {
    const launch = await loadAgentLaunch({
      workspacePath: nextWorkspacePath,
      dataDirectory: await agentDataDirectory(),
      settings,
    });
    await connection.connect(launch);
    activeLaunchKey = key;
  } catch (error) {
    if (error instanceof AgentLaunchError) {
      connection.reportConnectionFailure(translator()(LAUNCH_FAILURE_KEYS[error.failure]));
      return;
    }
    throw error;
  }
}

/** Stop the agent and wait for its process tree to exit. */
export async function closeAgentConnection(): Promise<void> {
  if (model === null) return;
  activeLaunchKey = null;
  await model.stop();
}
