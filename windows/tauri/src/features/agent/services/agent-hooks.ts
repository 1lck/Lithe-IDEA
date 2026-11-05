import { invoke } from "@/platform/tauri-core";
import { resolveAppDataDirectory } from "@/platform/app-data-directory";

export const hookEvents = ["turn-end", "after-tool", "before-tool", "prompt", "session-start"] as const;
export const hookMatchers = ["all", "shell", "edit"] as const;
export const hookAgents = ["codex-acp", "claude-acp"] as const;
export interface AgentHook {
  id: string; name: string; description: string; event: typeof hookEvents[number];
  matcher: typeof hookMatchers[number]; command: string; timeoutSeconds: number | null;
  agents: string[]; enabled: boolean; pendingRemoval: boolean;
}
export interface HookFileGuard { agentId: string; path: string; revision: string }
export interface HookTarget { agentId: string; file: HookFileGuard | null; issue: string | null; disabled: boolean }
export interface HookEntry extends AgentHook { configuredAgents: string[]; needsSync: boolean }
export interface HookLibrary { revision: string; hooks: HookEntry[]; targets: HookTarget[] }
const record = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(item => typeof item === "string");
const fileGuard = (value: unknown): value is HookFileGuard => record(value)
  && ["agentId", "path", "revision"].every(key => typeof value[key] === "string");

export function parseHookLibrary(value: unknown): HookLibrary | null {
  if (!record(value) || typeof value.revision !== "string" || !Array.isArray(value.hooks) || !Array.isArray(value.targets)) return null;
  if (!value.hooks.every(h => record(h) && ["id", "name", "description", "command"].every(key => typeof h[key] === "string")
    && hookEvents.includes(h.event as AgentHook["event"]) && hookMatchers.includes(h.matcher as AgentHook["matcher"])
    && (h.timeoutSeconds === null || (Number.isInteger(h.timeoutSeconds) && Number(h.timeoutSeconds) >= 1 && Number(h.timeoutSeconds) <= 86400))
    && strings(h.agents) && h.agents.every(id => hookAgents.includes(id as typeof hookAgents[number]))
    && typeof h.enabled === "boolean" && typeof h.pendingRemoval === "boolean" && strings(h.configuredAgents) && typeof h.needsSync === "boolean")) return null;
  if (!value.targets.every(target => record(target) && typeof target.agentId === "string" && typeof target.disabled === "boolean"
    && (target.issue === null || typeof target.issue === "string")
    && (target.file === null || fileGuard(target.file)))) return null;
  return value as unknown as HookLibrary;
}

/** One field-level problem from Core; `field` and `code` are stable identifiers for localization. */
export interface HookDraftIssue { field: string; code: string }
/** Core verdict for an unsaved draft; `timeoutSeconds` is the parsed value to store. */
export interface HookDraftValidation { valid: boolean; issues: HookDraftIssue[]; timeoutSeconds: number | null }

function parseDraftValidation(value: unknown): HookDraftValidation | null {
  if (!record(value) || typeof value.valid !== "boolean" || !Array.isArray(value.issues)) return null;
  if (!value.issues.every(issue => record(issue) && typeof issue.field === "string" && typeof issue.code === "string")) return null;
  if (value.timeoutSeconds !== null && !Number.isInteger(value.timeoutSeconds)) return null;
  return value as unknown as HookDraftValidation;
}

/**
 * Validates an unsaved draft with the rules `agent.hooks` save enforces. The raw
 * timeout text goes to Core so integer parsing and the range rule have one owner.
 */
export async function validateHookDraft(hook: AgentHook, timeoutText: string, library: HookLibrary): Promise<HookDraftValidation> {
  const value = await invoke<unknown>("agent.hooks.validateDraft", {
    hook: {
      id: hook.id, name: hook.name, description: hook.description, event: hook.event, matcher: hook.matcher,
      command: hook.command, timeoutText, agents: hook.agents,
    },
    existingHooks: library.hooks.map(entry => ({ id: entry.id, name: entry.name })),
  });
  const result = parseDraftValidation(value);
  if (!result) throw new Error("The Hook draft validation response was not recognised.");
  return result;
}

/** Localization key for one Core draft issue. */
export const hookDraftIssueKey = (issue: HookDraftIssue) => `agent.hooks.draft.${issue.field}.${issue.code}`;

/** Only configuration is written. Native runtimes retain shell, stdin and trust ownership. */
export async function manageHooks(action: "read" | "save" | "remove" | "sync", library?: HookLibrary, hook?: AgentHook, id?: string): Promise<HookLibrary> {
  const root = await resolveAppDataDirectory();
  const value = await invoke<unknown>("agent.hooks", {
    dataDirectory: `${root}/AgentHooks`, action,
    ...(action !== "read" && library ? { expectedRevision: library.revision, files: library.targets.flatMap(target => target.file ? [target.file] : []) } : {}),
    ...(hook ? { hook } : {}), ...(id ? { id } : {}),
  });
  const result = parseHookLibrary(value);
  if (!result) throw new Error("The Hook library response was not recognised.");
  return result;
}
