import type { GitExecutionEvent } from "@/platform/git-execution-events";

export interface GitConsoleRecord {
  id: string;
  operationId: string;
  root: string;
  action: string;
  arguments: string[];
  state: "queued" | "running" | "completed" | "unconfirmed";
  output: string;
  executable?: string | null;
  temporaryConfig?: string[][];
  phase?: GitExecutionEvent["progressDetails"];
  remoteResult?: GitExecutionEvent;
  progress?: string;
  truncated: boolean;
  exitCode?: number;
  durationMilliseconds?: number;
  error?: string;
}

const MAX_RECORDS = 200;
const MAX_OUTPUT = 65_536;
const MAX_TOTAL_OUTPUT = 1_048_576;

/** Receives complete sanitized native lines. State is intentionally memory-only. */
export class GitExecutionJournal {
  records: GitConsoleRecord[] = [];
  active = new Map<string, string>();
  authentication: GitExecutionEvent[] = [];
  private hidden = new Set<string>();

  clear(root: string) {
    this.records = this.records.filter((record) => !sameGitRoot(record.root, root));
    for (const [id, directory] of this.active) if (sameGitRoot(directory, root)) this.hidden.add(id);
  }

  receive(event: GitExecutionEvent) {
    const operationId = event.operationId;
    if (event.type === "authentication") { this.authentication.push(event); return; }
    if (event.type === "requestStarted") {
      this.active.set(operationId, event.workingDirectory ?? "");
      if (!this.hidden.has(operationId)) this.records.push({ id: operationId, operationId,
        root: event.workingDirectory ?? "", action: event.action ?? "Git", arguments: [], state: "queued", output: "", truncated: false });
    }
    if (event.type === "requestFinished") {
      this.authentication = this.authentication.filter((request) => request.operationId !== operationId);
      this.active.delete(operationId);
      if (this.hidden.delete(operationId)) return;
      const records = this.records.filter((record) => record.operationId === operationId);
      const last = records[records.length - 1];
      if (last && event.error) last.error = redactConsoleText(event.error.message);
      for (const record of records) {
        if (record.state === "running" || record.state === "queued") record.state = "unconfirmed";
      }
      return;
    }
    if (this.hidden.has(operationId)) return;
    if (event.type === "remoteResult") {
      const record = [...this.records].reverse().find((record) => record.operationId === operationId);
      if (record) { record.remoteResult = event; if (event.error) record.error = event.error.message; }
      return;
    }
    const id = `${operationId}:${event.invocationId}`;
    if (event.type === "started") {
      this.records = this.records.filter((record) => record.id !== operationId);
      this.records.push({ id, operationId, root: event.workingDirectory ?? "", action: event.action ?? "Git",
        arguments: event.arguments ?? [], executable: event.executable, temporaryConfig: event.temporaryConfig, state: "running", output: "", truncated: false });
    }
    const record = [...this.records].reverse().find((record) => record.id === id);
    if (record && event.type === "output") {
      record.phase = event.progressDetails ?? record.phase;
      if (event.progress) record.progress = event.text;
      else { record.output += (event.text ?? "") + "\n"; record.progress = undefined; }
      if (record.output.length > MAX_OUTPUT) { record.output = record.output.slice(-MAX_OUTPUT); record.truncated = true; }
      record.truncated ||= !!event.truncated;
    }
    if (record && event.type === "finished") {
      record.state = event.exitCode == null ? "unconfirmed" : "completed";
      record.exitCode = event.exitCode ?? undefined;
      record.durationMilliseconds = event.durationMilliseconds;
      record.error = event.error ? [event.error.message, event.error.details].filter(Boolean).join("\n") : undefined;
      record.progress = undefined;
    }
    while (this.records.length > MAX_RECORDS || (this.records.length > 1 && this.records.reduce((sum, record) => sum + record.output.length, 0) > MAX_TOTAL_OUTPUT)) {
      this.records.shift();
    }
  }
}

export function redactConsoleText(text: string): string {
  return text.replace(/(https?|ssh):\/\/[^\s/@]+(?::[^\s/@]*)?@/gi, "$1://redacted@")
    .replace(/([?&](?:token|access_token|password|secret|api_key)=)[^&\s]+/gi, "$1redacted");
}

export function gitConsoleCommand(arguments_: string[]): string {
  return "git " + arguments_.map((argument) => {
    const value = redactConsoleText(argument).replace(/\r/g, "\\r").replace(/\n/g, "\\n");
    return /^[a-zA-Z0-9_@%+=:,./-]+$/.test(value) ? value : "'" + value.replace(/'/g, "'\\''") + "'";
  }).join(" ");
}

export function sameGitRoot(left: string, right: string | null): boolean {
  const normalize = (value: string) => value.replace(/\\/g, "/").replace(/\/+$/, "").toLocaleLowerCase();
  return right !== null && normalize(left) === normalize(right);
}
