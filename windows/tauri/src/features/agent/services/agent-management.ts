/**
 * Adapter status and installs, through the shared `agent.*` core commands.
 *
 * Node.js and npm belong to the user; Lithe only detects them and installs the
 * ACP adapter with the user's npm. The response shape is fixed by
 * `shared/fixtures/agent/agent-management-v1.json`, so it is parsed here
 * instead of being trusted field by field in the panel.
 */

import { Channel, invoke } from "@/platform/tauri-core";

export interface DetectedRuntime {
  version: string;
  path: string;
}

export interface AgentCliInstallation {
  source: string;
  canUpdate: boolean;
  updateHint: string;
}

export interface AgentCliStatus {
  name: string;
  command: string;
  minimumVersion: string;
  installHint: string;
  detected: DetectedRuntime | null;
  installation: AgentCliInstallation;
}

export interface CatalogAgentStatus {
  id: string;
  name: string;
  description: string;
  package: string;
  version: string;
  installedVersion: string | null;
  protocol: string;
  minimumNodeMajor: number;
  verified: boolean;
  cli: AgentCliStatus | null;
  issues: string[];
}

export interface AgentEnvironmentStatus {
  node: DetectedRuntime | null;
  npm: DetectedRuntime | null;
}

export interface AgentManagementStatus {
  environment: AgentEnvironmentStatus;
  agents: CatalogAgentStatus[];
}

export interface AgentInstallProgress {
  stage: string;
  downloadedBytes: number;
  bytesPerSecond: number;
  elapsedMilliseconds: number;
  idleMilliseconds: number;
}

/**
 * Verified outcome of `agent.installCli`. The warning carries a bounded
 * installer log tail when the updater reported failure but the CLI was
 * verifiably updated; it is never error input.
 */
export interface AgentCliUpdateResult {
  cliVersion: string;
  updaterWarning: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function runtime(value: unknown): DetectedRuntime | null {
  if (!isRecord(value)) return null;
  const version = asString(value.version);
  const path = asString(value.path);
  return version !== null && path !== null ? { version, path } : null;
}

/**
 * One `agentInstallProgress` event, or `null` for anything else the channel
 * carries. The counters are read after validation, so the panel never renders
 * `undefined` megabytes.
 */
export function installProgressEvent(value: unknown): AgentInstallProgress | null {
  if (!isRecord(value) || value.kind !== "agentInstallProgress") return null;
  const progress = value.progress;
  if (!isRecord(progress)) return null;
  const counter = (field: string) =>
    typeof progress[field] === "number" ? (progress[field] as number) : 0;
  return {
    stage: asString(progress.stage) ?? "",
    downloadedBytes: counter("downloadedBytes"),
    bytesPerSecond: counter("bytesPerSecond"),
    elapsedMilliseconds: counter("elapsedMilliseconds"),
    idleMilliseconds: counter("idleMilliseconds"),
  };
}

/**
 * Read the documented `agent.installCli` response, or `null` when it is not
 * recognised. Responses from hosts that predate `updaterWarning` decode as a
 * clean result.
 */
export function parseAgentCliUpdateResult(value: unknown): AgentCliUpdateResult | null {
  if (!isRecord(value)) return null;
  const cliVersion = asString(value.cliVersion);
  if (cliVersion === null || cliVersion.length === 0) return null;
  const warning = (asString(value.updaterWarning) ?? "").trim();
  return { cliVersion, updaterWarning: warning.length > 0 ? warning : null };
}

function cliStatus(value: unknown): AgentCliStatus | null {
  if (!isRecord(value)) return null;
  const installation = isRecord(value.installation) ? value.installation : {};
  return {
    name: asString(value.name) ?? "",
    command: asString(value.command) ?? "",
    minimumVersion: asString(value.minimumVersion) ?? "",
    installHint: asString(value.installHint) ?? "",
    detected: runtime(value.detected),
    installation: {
      source: asString(installation.source) ?? "unknown",
      canUpdate: installation.canUpdate === true,
      updateHint: asString(installation.updateHint) ?? "",
    },
  };
}

/** Read one agent entry, or `null` when the shape is not the documented one. */
function agentStatus(value: unknown): CatalogAgentStatus | null {
  if (!isRecord(value)) return null;
  const id = asString(value.id);
  if (id === null) return null;
  const issues = Array.isArray(value.issues)
    ? value.issues.filter((issue): issue is string => typeof issue === "string")
    : [];
  return {
    id,
    name: asString(value.name) ?? id,
    description: asString(value.description) ?? "",
    package: asString(value.package) ?? "",
    version: asString(value.version) ?? "",
    installedVersion: asString(value.installedVersion),
    protocol: asString(value.protocol) ?? "",
    minimumNodeMajor: typeof value.minimumNodeMajor === "number" ? value.minimumNodeMajor : 0,
    verified: value.verified === true,
    cli: cliStatus(value.cli),
    issues,
  };
}

export function parseAgentManagementStatus(value: unknown): AgentManagementStatus | null {
  if (!isRecord(value)) return null;
  const environment = isRecord(value.environment) ? value.environment : {};
  const agents = Array.isArray(value.agents)
    ? value.agents.flatMap((entry) => {
        const parsed = agentStatus(entry);
        return parsed === null ? [] : [parsed];
      })
    : [];
  return {
    environment: { node: runtime(environment.node), npm: runtime(environment.npm) },
    agents,
  };
}

export async function loadAgentManagementStatus(
  dataDirectory: string,
): Promise<AgentManagementStatus> {
  const response = await invoke<unknown>("agent.status", { dataDirectory });
  const status = parseAgentManagementStatus(response);
  if (status === null) throw new Error("The Agent status response was not recognised.");
  return status;
}

/** Channel that forwards one operation's `agentInstallProgress` events. */
function installProgressChannel(
  onProgress?: (progress: AgentInstallProgress) => void,
): Channel<unknown> | undefined {
  if (onProgress === undefined) return undefined;
  const channel = new Channel<unknown>();
  channel.onmessage = (event) => {
    const progress = installProgressEvent(event);
    if (progress !== null) onProgress(progress);
  };
  return channel;
}

/** Install one adapter, reporting npm transfer progress through a channel. */
export async function installAgent(
  dataDirectory: string,
  agentId: string,
  onProgress?: (progress: AgentInstallProgress) => void,
): Promise<void> {
  const channel = installProgressChannel(onProgress);
  await invoke(
    "agent.install",
    { dataDirectory, agentId },
    channel === undefined ? undefined : { agentEvents: channel },
  );
}

/**
 * Install or update the agent's own CLI through the installation owner the
 * host re-resolves on this call, so no remembered installation facts travel
 * with the request.
 */
export async function installAgentCli(
  dataDirectory: string,
  agentId: string,
  onProgress?: (progress: AgentInstallProgress) => void,
): Promise<AgentCliUpdateResult> {
  const channel = installProgressChannel(onProgress);
  const response = await invoke<unknown>(
    "agent.installCli",
    { dataDirectory, agentId },
    channel === undefined ? undefined : { agentEvents: channel },
  );
  const result = parseAgentCliUpdateResult(response);
  if (result === null) throw new Error("The Agent CLI update response was not recognised.");
  return result;
}

export async function uninstallAgent(dataDirectory: string, agentId: string): Promise<void> {
  await invoke("agent.uninstall", { dataDirectory, agentId });
}
