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

/** Sentinel for a documented field that is present but not the documented shape. */
const INVALID = Symbol("invalid");

function optionalRuntime(value: unknown): DetectedRuntime | null | typeof INVALID {
  if (value === null) return null;
  if (!isRecord(value)) return INVALID;
  const version = asString(value.version);
  const path = asString(value.path);
  return version !== null && path !== null ? { version, path } : INVALID;
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

/** One CLI's install provenance, or `null` when the host reported none. */
function optionalCliInstallation(value: unknown): AgentCliInstallation | null | typeof INVALID {
  if (value === null) return null;
  if (!isRecord(value)) return INVALID;
  const source = asString(value.source);
  const updateHint = asString(value.updateHint);
  const canUpdate = value.canUpdate;
  if (source === null || updateHint === null || typeof canUpdate !== "boolean") return INVALID;
  return { source, canUpdate, updateHint };
}

function cliStatus(value: unknown): AgentCliStatus | null | typeof INVALID {
  if (value === null) return null;
  if (!isRecord(value)) return INVALID;
  const name = asString(value.name);
  const command = asString(value.command);
  const minimumVersion = asString(value.minimumVersion);
  const installHint = asString(value.installHint);
  const detected = optionalRuntime(value.detected);
  const installation = optionalCliInstallation(value.installation);
  if (
    name === null ||
    command === null ||
    minimumVersion === null ||
    installHint === null ||
    detected === INVALID ||
    installation === INVALID
  ) {
    return INVALID;
  }

  return {
    name,
    command,
    minimumVersion,
    installHint,
    detected,
    // Without provenance Lithe only offers manual guidance, so an absent report
    // means an unknown source rather than a missing field.
    installation: installation ?? { source: "unknown", canUpdate: false, updateHint: "" },
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

/**
 * Read one agent entry. The shared host always serializes every documented
 * field, so a missing or mistyped one means the response is not this contract
 * and must not be half read into a catalog row.
 */
function agentStatus(value: unknown): CatalogAgentStatus | null {
  if (!isRecord(value)) return null;
  const id = asString(value.id);
  const name = asString(value.name);
  const description = asString(value.description);
  const packageName = asString(value.package);
  const version = asString(value.version);
  const protocol = asString(value.protocol);
  const rawInstalled = value.installedVersion;
  const installedVersion = rawInstalled === null ? null : asString(rawInstalled);
  const minimumNodeMajor = value.minimumNodeMajor;
  const verified = value.verified;
  const rawIssues = value.issues;
  const cli = cliStatus(value.cli);
  if (
    id === null ||
    name === null ||
    description === null ||
    packageName === null ||
    version === null ||
    protocol === null ||
    (installedVersion === null && rawInstalled !== null) ||
    typeof minimumNodeMajor !== "number" ||
    typeof verified !== "boolean" ||
    !Array.isArray(rawIssues) ||
    cli === INVALID
  ) {
    return null;
  }
  const issues: string[] = [];
  for (const issue of rawIssues) {
    if (typeof issue !== "string") return null;
    issues.push(issue);
  }
  return {
    id,
    name,
    description,
    package: packageName,
    version,
    installedVersion,
    protocol,
    minimumNodeMajor,
    verified,
    cli,
    issues,
  };
}

/**
 * Read the whole `agent.status` response, or `null` when it violates the shared
 * contract. An unreadable status has to reach the caller as an error instead of
 * looking like a machine with nothing installed.
 */
export function parseAgentManagementStatus(value: unknown): AgentManagementStatus | null {
  if (!isRecord(value)) return null;
  const environment = value.environment;
  if (!isRecord(environment)) return null;
  const node = optionalRuntime(environment.node);
  const npm = optionalRuntime(environment.npm);
  const rawAgents = value.agents;
  if (node === INVALID || npm === INVALID || !Array.isArray(rawAgents)) return null;
  const agents: CatalogAgentStatus[] = [];
  for (const entry of rawAgents) {
    const parsed = agentStatus(entry);
    if (parsed === null) return null;
    agents.push(parsed);
  }
  return { environment: { node, npm }, agents };
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
