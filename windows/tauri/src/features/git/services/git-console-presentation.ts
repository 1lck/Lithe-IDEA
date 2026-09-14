import type { GitConsoleRecord } from "./git-execution-journal";

/** Core owns compression and parsing; native views own only disclosure state. */
export interface ConsoleCommandFragment {
  id: string; kind: string; text: string; preview: string; count: number; matches: number;
}
export interface ConsoleOutputFragment {
  id: string; start: number; end: number; kind: string; count: number;
  added: number; updated: number; deleted: number; matches: number;
}
export interface ConsolePresentationEntry {
  id: string; repositoryLabel: string; command: ConsoleCommandFragment[];
  output: ConsoleOutputFragment[]; failed: boolean;
  notice?: "waitingForOutput" | "completedWithoutOutput" | "fetchUnchanged" | null;
}
export interface ConsoleSearchHit { recordId: string; fragmentId: string; lineIndex: number | null }
export interface ConsolePresentation {
  entries: ConsolePresentationEntry[];
  groups: { id: string; recordIds: string[]; matches: number }[];
  matches: ConsoleSearchHit[];
  totalMatches: number;
}
export function consolePresentationRequest(records: GitConsoleRecord[], search: string, repositoryRoots: string[] = []) {
  return { search, repositoryRoots, records: records.map((record) => ({
    id: record.id, sequence: record.sequence ?? null, root: record.root, arguments: record.arguments,
    temporaryConfig: record.temporaryConfig ?? [], lines: record.lines, state: record.state,
    expectedExit: record.expectedExit ?? false, exitCode: record.exitCode ?? null, error: record.error ?? null,
    executable: record.executable ?? null, progress: record.progress ?? null,
    source: record.source ?? "unknown", truncated: record.truncated,
    remoteResult: record.remoteResult ?? null,
  })) };
}
export function consoleSearchAnchor(hit: ConsoleSearchHit): string {
  return `${hit.recordId}:${hit.lineIndex == null ? hit.fragmentId : `line-${hit.lineIndex}`}`;
}
