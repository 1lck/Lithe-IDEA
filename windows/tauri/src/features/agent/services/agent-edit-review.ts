import type { AgentConversationMessage, AgentToolDiff } from "../types/agent.types";

/** Host evidence plus the ACP kind of the tool that reported it. */
export interface AgentFileChangeDiff extends AgentToolDiff {
  toolKind: string | null;
}

export interface AgentFileChange {
  path: string;
  versions: string[];
  diffs: AgentFileChangeDiff[];
  /** A tool touched the file without diff evidence, or moved it. */
  missingEvidence: boolean;
  /** Presentation: some evidence is missing or truncated. */
  incomplete: boolean;
  pending: boolean;
}

/** Acknowledgements cover an exact prefix; replacement evidence stays visible. */
export function agentFileChanges(messages: AgentConversationMessage[], reviewed: Record<string, string[]> = {}): AgentFileChange[] {
  const files = new Map<string, AgentFileChange>();
  for (const tool of messages) {
    if (tool.role !== "tool" || tool.toolStatus === "failed" || tool.toolStatus === "interrupted") continue;
    const details = tool.toolDetails;
    const diffs = details.diffs ?? [];
    if (diffs.length === 0 && !["edit", "delete", "move"].includes(details.kind ?? "")) continue;
    const paths = new Set([...diffs.map((diff) => diff.path), ...details.locations.map((location) => location.path)]);
    for (const path of paths) {
      const selected = diffs.filter((diff) => diff.path === path);
      const file = files.get(path) ?? { path, versions: [], diffs: [], missingEvidence: false, incomplete: false, pending: false };
      file.versions.push(JSON.stringify([tool.id, tool.toolStatus, details.kind, selected]));
      file.diffs.push(...selected.map((diff) => ({ ...diff, toolKind: details.kind })));
      file.missingEvidence ||= selected.length === 0 || details.kind === "move";
      file.incomplete ||= file.missingEvidence || selected.some((diff) => diff.incomplete);
      file.pending ||= tool.toolStatus !== "completed";
      files.set(path, file);
    }
  }
  return [...files.values()].flatMap((file) => {
    const prefix = reviewed[file.path];
    if (!prefix || !prefix.every((version, index) => file.versions[index] === version)) return [file];
    if (prefix.length === file.versions.length) return [];
    // Re-derive the remaining tools instead of slicing hunks by tool count.
    const ids = new Set(prefix.map((version) => (JSON.parse(version) as [string])[0]));
    const remainder = agentFileChanges(messages.filter((tool) => !ids.has(tool.id))).find((entry) => entry.path === file.path);
    return remainder ? [{ ...remainder, versions: file.versions }] : [file];
  });
}

/** Agent Host decides per-diff eligibility; `agent.edits.reversePlan` rechecks it. */
export function canRevertAgentChange(change: AgentFileChange): boolean {
  return !change.pending && !change.missingEvidence && change.diffs.length > 0 && change.diffs.every((diff) => diff.revertible);
}

/** Payload of `agent.edits.reversePlan` (shared/contracts/agent-edit-review.md). */
export function agentReversePlanRequest(change: AgentFileChange, disk: string | null) {
  return {
    diffs: change.diffs.map((diff) => ({ oldText: diff.oldText, newText: diff.newText, operation: diff.operation,
      toolKind: diff.toolKind, truncated: diff.incomplete })),
    pending: change.pending,
    missingEvidence: change.missingEvidence,
    disk,
  };
}

/** Core rollback plan; conflicts carry a stable reason instead of a write. */
export type AgentReversePlan =
  | { action: "write"; text: string }
  | { action: "trash" }
  | { action: "none" }
  | { action: "conflict"; reason: "changed" | "incomplete" };
