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
import { AgentConnectionModel } from "./agent-connection.model";

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
 * Start the agent for `nextWorkspacePath`, or report why it cannot start. A
 * second call while connected to the same project is a no-op.
 */
export async function openAgentConnection(
  nextWorkspacePath: string,
  settings: AgentPanelSettings,
): Promise<void> {
  const connection = agentConnection();
  if (workspacePath !== nextWorkspacePath) {
    await connection.stop();
    connection.reset();
    workspacePath = nextWorkspacePath;
  }
  if (connection.hasActiveConnection) return;
  try {
    const launch = await loadAgentLaunch({
      workspacePath: nextWorkspacePath,
      dataDirectory: await agentDataDirectory(),
      settings,
    });
    await connection.connect(launch);
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
  await model.stop();
}

/** Drop the project binding, e.g. when a window returns to the welcome screen. */
export async function releaseAgentConnection(): Promise<void> {
  await closeAgentConnection();
  model?.reset();
  workspacePath = null;
}
