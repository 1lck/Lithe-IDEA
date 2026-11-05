import type { GitExecutionEvent, GitJournalRetention } from "@/platform/git-execution-events";

export interface GitConsoleRecord {
  id: string;
  timestamp: number;
  sequence?: number;
  operationId: string;
  source?: GitExecutionEvent["source"];
  root: string;
  action: string;
  arguments: string[];
  state: "queued" | "running" | "completed" | "unconfirmed";
  output: string;
  lines: { stream: "stdout" | "stderr"; text: string }[];
  executable?: string | null;
  temporaryConfig?: string[][];
  displayArguments?: string[];
  globalArguments?: string[];
  phase?: GitExecutionEvent["progressDetails"];
  remoteResult?: GitExecutionEvent;
  progress?: string;
  truncated: boolean;
  expectedExit?: boolean;
  exitCode?: number;
  durationMilliseconds?: number;
  error?: string;
}

/**
 * Stores the ordered native events Core emits. State is intentionally memory-only.
 *
 * Core owns record states, redaction, and the retention budget (carried by
 * `requestStarted`); the journal only stores, trims to that budget, and exposes records.
 */
export class GitExecutionJournal {
  constructor(private readonly now: () => number = Date.now) {}
  records: GitConsoleRecord[] = [];
  historyTruncated = false;
  active = new Map<string, string>();
  authentication: GitExecutionEvent[] = [];
  private hidden = new Set<string>();
  private pending = new Map<string, { root: string; action: string }>();
  private sequence = 0;
  private retention: GitJournalRetention | null = null;

  clear(root?: string) {
    this.records = this.records.filter((record) => root != null && !sameGitRoot(record.root, root));
    if (!this.records.length) this.historyTruncated = false;
    for (const [id, directory] of this.active) if (root == null || sameGitRoot(directory, root)) this.hidden.add(id);
  }

  receive(event: GitExecutionEvent) {
    const operationId = event.operationId;
    if (event.type === "started") this.sequence += 1;
    if (event.type === "authentication") { this.authentication.push(event); return; }
    if (event.type === "requestStarted") {
      if (event.retention) this.retention = event.retention;
      this.active.set(operationId, event.workingDirectory ?? "");
      this.pending.set(operationId, { root: event.workingDirectory ?? "", action: event.action ?? "Git" });
      return;
    }
    if (event.type === "requestFinished") {
      const pending = this.pending.get(operationId);
      this.pending.delete(operationId);
      this.authentication = this.authentication.filter((request) => request.operationId !== operationId);
      this.active.delete(operationId);
      if (this.hidden.delete(operationId)) return;
      const records = this.records.filter((record) => record.operationId === operationId);
      let last = records[records.length - 1];
      // A failed preflight needs its reason, but is never presented as an executed command.
      if (!last && event.failureRecord && event.error) {
        last = { id: operationId, operationId, timestamp: this.now(), root: pending?.root ?? event.workingDirectory ?? "",
          action: pending?.action ?? event.action ?? "Git", arguments: [], state: "unconfirmed", output: "", lines: [], truncated: false };
        this.records.push(last);
      }
      if (last && event.error) last.error = [event.error.message, event.error.details].filter(Boolean).join("\n");
      const unconfirmed = new Set(event.unconfirmedInvocations ?? []);
      for (const record of records) {
        if (unconfirmed.has(Number(record.id.slice(operationId.length + 1)))) record.state = "unconfirmed";
      }
      this.trimHistory();
      return;
    }
    if (this.hidden.has(operationId)) return;
    if (event.type === "remoteResult") {
      const record = [...this.records].reverse().find((record) => record.operationId === operationId && (event.invocationId == null || record.id === `${operationId}:${event.invocationId}`));
      if (record) { record.remoteResult = event; if (event.error) record.error = event.error.message; }
      return;
    }
    const id = `${operationId}:${event.invocationId}`;
    if (event.type === "started") {
      this.pending.delete(operationId);
      this.active.set(operationId, event.workingDirectory ?? "");
      this.records.push({ id, operationId, timestamp: this.now(), sequence: this.sequence, root: event.workingDirectory ?? "", action: event.action ?? "Git",
        source: event.source ?? "unknown", arguments: event.arguments ?? [], executable: event.executable, temporaryConfig: event.temporaryConfig,
        displayArguments: event.displayArguments, globalArguments: event.globalArguments, state: "running", output: "", lines: [], truncated: false });
    }
    const record = [...this.records].reverse().find((record) => record.id === id);
    if (record && event.type === "output") {
      record.phase = event.progressDetails ?? record.phase;
      if (event.progress) record.progress = event.text ?? "";
      else {
        const limits = this.retention;
        const text = limits ? (event.text ?? "").slice(-(limits.maxRecordOutputCharacters - 1)) : (event.text ?? "");
        record.lines.push({ stream: event.stream === "stderr" ? "stderr" : "stdout", text });
        if (limits) {
          let characters = record.output.length + text.length + 1;
          while (record.lines.length > 1 && (characters > limits.maxRecordOutputCharacters || record.lines.length > limits.maxRecordOutputLines)) {
            characters -= record.lines.shift()!.text.length + 1;
            record.truncated = true;
          }
          record.truncated ||= (event.text ?? "").length >= limits.maxRecordOutputCharacters;
        }
        record.output = record.lines.map((line) => line.text + "\n").join("");
        record.progress = undefined;
      }
      record.truncated ||= !!event.truncated;
    }
    if (record && event.type === "finished") {
      record.state = event.state ?? "unconfirmed";
      record.exitCode = event.exitCode ?? undefined;
      record.expectedExit = event.expectedExit ?? false;
      record.durationMilliseconds = event.durationMilliseconds;
      record.error = event.error ? [event.error.message, event.error.details].filter(Boolean).join("\n") : undefined;
      record.progress = undefined;
    }
    this.trimHistory();
  }

  private trimHistory() {
    const limits = this.retention;
    if (!limits) return;
    while (this.records.length > limits.maxRecords || (this.records.length > 1 && this.records.reduce((sum, record) => sum + record.output.length, 0) > limits.maxTotalOutputCharacters)) {
      this.historyTruncated = true;
      this.records.shift();
    }
  }
}

export function redactConsoleText(text: string): string {
  return text.replace(/(https?|ssh):\/\/[^\s/@]+(?::[^\s/@]*)?@/gi, "$1://redacted@")
    .replace(/([?&](?:token|access_token|password|secret|api_key)=)[^&\s]+/gi, "$1redacted");
}

export function gitConsoleCommand(arguments_: string[], preservesNewlines = false): string {
  return "git " + arguments_.map((argument) => {
    let value = redactConsoleText(argument).replace(/\r/g, "\\r");
    if (!preservesNewlines) value = value.replace(/\n/g, "\\n");
    return /^[a-zA-Z0-9_@%+=:,./-]+$/.test(value) ? value : "'" + value.replace(/'/g, "'\\''") + "'";
  }).join(" ");
}

export function gitConsoleTimestamp(timestamp: number): string {
  const date = new Date(timestamp);
  return [date.getHours(), date.getMinutes(), date.getSeconds()]
    .map((value) => String(value).padStart(2, "0")).join(":") + "." + String(date.getMilliseconds()).padStart(3, "0");
}

export function gitConsoleConfiguration(values: string[][] = []): string {
  return values.map(([key, value]) => gitConsoleCommand(["-c", `${key}=${value}`]).slice(4)).join(" ");
}

export function sameGitRoot(left: string, right: string | null): boolean {
  const normalize = (value: string) => value.replace(/\\/g, "/").replace(/\/+$/, "").toLocaleLowerCase();
  return right !== null && normalize(left) === normalize(right);
}

/** Copy from actual argv and explicit temporary configuration, never a reordered display plan. */
export function gitConsoleCompleteCommand(record: GitConsoleRecord): string {
  return gitConsoleCommand([...(record.temporaryConfig ?? []).flatMap((pair) => ["-c", pair.join("=")]), ...record.arguments], true);
}
