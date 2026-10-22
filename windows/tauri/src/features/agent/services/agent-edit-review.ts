import type { AgentConversationMessage, AgentToolDiff } from "../types/agent.types";

export interface AgentFileChange {
  path: string;
  versions: string[];
  diffs: AgentToolDiff[];
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
      const file = files.get(path) ?? { path, versions: [], diffs: [], incomplete: false, pending: false };
      file.versions.push(JSON.stringify([tool.id, tool.toolStatus, details.kind, selected]));
      file.diffs.push(...selected);
      file.incomplete ||= selected.length === 0 || details.kind === "move" || selected.some((diff) => diff.incomplete);
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

export function canRevertAgentChange(change: AgentFileChange): boolean {
  return !change.pending && !change.incomplete && change.diffs.length > 0 &&
    change.diffs.every((diff) => !diff.incomplete && (diff.oldText !== null || diff.operation === "add"));
}

function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n?/g, "\n");
}

function dominantLineEnding(value: string): "\n" | "\r\n" {
  return value.includes("\r\n") ? "\r\n" : "\n";
}

function withLineEnding(value: string, lineEnding: "\n" | "\r\n"): string {
  return normalizeLineEndings(value).replace(/\n/g, lineEnding);
}

function uniqueTextReplacement(restored: string, newText: string, oldText: string): string | null {
  if (restored === newText) return oldText;

  const lineEnding = dominantLineEnding(restored);
  const diskNewText = withLineEnding(newText, lineEnding);
  const diskOldText = withLineEnding(oldText, lineEnding);
  const exactIndex = restored.indexOf(diskNewText);
  if (exactIndex >= 0) {
    if (restored.indexOf(diskNewText, exactIndex + 1) >= 0) return null;
    return restored.slice(0, exactIndex) + diskOldText + restored.slice(exactIndex + diskNewText.length);
  }

  // ACP diffs use LF while Windows document reads may return CRLF. Compare
  // canonically, but preserve the disk's line-ending style in the result.
  const canonicalRestored = normalizeLineEndings(restored);
  const canonicalNewText = normalizeLineEndings(newText);
  const canonicalIndex = canonicalRestored.indexOf(canonicalNewText);
  if (canonicalIndex < 0 || canonicalRestored.indexOf(canonicalNewText, canonicalIndex + 1) >= 0) {
    return null;
  }
  return withLineEnding(
    canonicalRestored.slice(0, canonicalIndex) + normalizeLineEndings(oldText) + canonicalRestored.slice(canonicalIndex + canonicalNewText.length),
    lineEnding,
  );
}

/** Reverse complete snapshots or exactly one nonempty excerpt, newest first. */
export function reverseAgentChange(change: AgentFileChange, disk: string | null): string | null {
  if (!canRevertAgentChange(change)) throw new Error("agent.edits.incomplete");
  let restored = disk;
  for (const diff of [...change.diffs].reverse()) {
    if (diff.operation === "delete") {
      if (restored !== null || diff.oldText === null) throw new Error("agent.edits.changed");
      restored = diff.oldText;
    } else if (diff.oldText === null) {
      if (diff.operation !== "add" || restored === null || normalizeLineEndings(restored) !== normalizeLineEndings(diff.newText)) {
        throw new Error("agent.edits.changed");
      }
      restored = null;
    } else if (restored !== null) {
      const replacement = uniqueTextReplacement(restored, diff.newText, diff.oldText);
      if (replacement === null) throw new Error("agent.edits.changed");
      restored = replacement;
    }
  }
  return restored;
}
