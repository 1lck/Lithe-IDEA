import type { GitExecutionEvent } from "@/platform/git-execution-events";

export interface GitConsoleRecord {
  id: string;
  timestamp: number;
  operationId: string;
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
  exitCode?: number;
  durationMilliseconds?: number;
  error?: string;
}

const MAX_RECORDS = 200;
const MAX_OUTPUT = 65_536;
const MAX_OUTPUT_LINES = 2_000;
const MAX_TOTAL_OUTPUT = 1_048_576;

/** Receives complete sanitized native lines. State is intentionally memory-only. */
export class GitExecutionJournal {
  constructor(private readonly now: () => number = Date.now) {}
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
      if (!this.hidden.has(operationId)) this.records.push({ id: operationId, operationId, timestamp: this.now(),
        root: event.workingDirectory ?? "", action: event.action ?? "Git", arguments: [], state: "queued", output: "", lines: [], truncated: false });
    }
    if (event.type === "requestFinished") {
      this.authentication = this.authentication.filter((request) => request.operationId !== operationId);
      this.active.delete(operationId);
      if (this.hidden.delete(operationId)) return;
      // A successful parser-only request has no visible Git invocation.
      // Remove its provisional row instead of reporting a fictitious failure.
      if (!event.error) this.records = this.records.filter((record) => record.id !== operationId);
      const records = this.records.filter((record) => record.operationId === operationId);
      const last = records[records.length - 1];
      if (last && event.error) last.error = redactConsoleText([event.error.message, event.error.details].filter(Boolean).join("\n"));
      for (const record of records) {
        if (record.state === "running" || record.state === "queued") record.state = "unconfirmed";
      }
      return;
    }
    if (this.hidden.has(operationId)) return;
    if (event.type === "remoteResult") {
      const record = [...this.records].reverse().find((record) => record.operationId === operationId);
      if (record) { record.remoteResult = event; if (event.error) record.error = redactConsoleText(event.error.message); }
      return;
    }
    const id = `${operationId}:${event.invocationId}`;
    if (event.type === "started") {
      this.records = this.records.filter((record) => record.id !== operationId);
      this.records.push({ id, operationId, timestamp: this.now(), root: event.workingDirectory ?? "", action: event.action ?? "Git",
        arguments: event.arguments ?? [], executable: event.executable, temporaryConfig: event.temporaryConfig,
        displayArguments: event.displayArguments, globalArguments: event.globalArguments, state: "running", output: "", lines: [], truncated: false });
    }
    const record = [...this.records].reverse().find((record) => record.id === id);
    if (record && event.type === "output") {
      record.phase = event.progressDetails ?? record.phase;
      if (event.progress) record.progress = redactConsoleText(event.text ?? "");
      else {
        const text = redactConsoleText(event.text ?? "");
        record.lines.push({ stream: event.stream === "stderr" ? "stderr" : "stdout", text: text.slice(-(MAX_OUTPUT - 1)) });
        let characters = record.output.length + record.lines[record.lines.length - 1].text.length + 1;
        while (record.lines.length > 1 && (characters > MAX_OUTPUT || record.lines.length > MAX_OUTPUT_LINES)) {
          characters -= record.lines.shift()!.text.length + 1;
          record.truncated = true;
        }
        record.truncated ||= text.length >= MAX_OUTPUT;
        record.output = record.lines.map((line) => line.text + "\n").join("");
        record.progress = undefined;
      }
      record.truncated ||= !!event.truncated;
    }
    if (record && event.type === "finished") {
      record.state = event.exitCode == null ? "unconfirmed" : "completed";
      record.exitCode = event.exitCode ?? undefined;
      record.durationMilliseconds = event.durationMilliseconds;
      record.error = event.error ? redactConsoleText([event.error.message, event.error.details].filter(Boolean).join("\n")) : undefined;
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
