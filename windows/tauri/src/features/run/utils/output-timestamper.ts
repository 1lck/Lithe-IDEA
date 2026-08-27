const LEADING_TIME_PATTERN = /^\s*(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}/;

function formatTimestamp(now: Date): string {
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  const seconds = String(now.getSeconds()).padStart(2, "0");
  const milliseconds = String(now.getMilliseconds()).padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${milliseconds} `;
}

export function leadingTimeLength(line: string): number | undefined {
  const match = LEADING_TIME_PATTERN.exec(line);
  if (!match) return undefined;
  let end = match[0].length;
  while (end < line.length) {
    const character = line[end];
    if (character !== "." && character !== " " && (character < "0" || character > "9")) {
      break;
    }
    end += 1;
    if (character === " ") break;
  }
  return end;
}

export function hasLeadingTime(line: string): boolean {
  return leadingTimeLength(skipLeadingOutputControls(line)) !== undefined;
}

// Colored tools often emit SGR/OSC before a clock. Skip those so we do not
// add a second timestamp after the escapes are stripped for display.
function skipLeadingOutputControls(line: string): string {
  let index = 0;
  while (index < line.length) {
    const code = line.charCodeAt(index);
    if (code === 32 || code === 9) {
      index += 1;
      continue;
    }
    if (code !== 27) break;
    if (index + 1 >= line.length) {
      index = line.length;
      break;
    }
    const next = line.charCodeAt(index + 1);
    if (next === 91) {
      let cursor = index + 2;
      while (cursor < line.length) {
        const finalCode = line.charCodeAt(cursor);
        if (finalCode >= 0x40 && finalCode <= 0x7e) {
          cursor += 1;
          break;
        }
        cursor += 1;
      }
      index = cursor;
      continue;
    }
    if (next === 93) {
      let cursor = index + 2;
      while (cursor < line.length) {
        const terminator = line.charCodeAt(cursor);
        if (terminator === 7) {
          cursor += 1;
          break;
        }
        if (terminator === 27 && line.charCodeAt(cursor + 1) === 92) {
          cursor += 2;
          break;
        }
        cursor += 1;
      }
      index = cursor;
      continue;
    }
    index += 1;
  }
  return line.slice(index);
}

function shouldStampLine(line: string): boolean {
  if (line.length === 0) return false;
  const visible = skipLeadingOutputControls(line);
  if (visible.length === 0) return false;
  return leadingTimeLength(visible) === undefined;
}

const INCOMPLETE_TIMESTAMP_PREFIX =
  /^\s*\d{4}-\d{0,2}(?:-\d{0,2}(?:[T ]\d{0,2}(?::\d{0,2}(?::\d{0,2})?)?)?)?$/;

function isIncompleteTimestampPrefix(visible: string): boolean {
  return INCOMPLETE_TIMESTAMP_PREFIX.test(visible);
}

function isUndecidedPrefix(line: string): boolean {
  if (line.length === 0) return false;
  const visible = skipLeadingOutputControls(line);
  if (visible.length === 0) return true;
  if (leadingTimeLength(visible) !== undefined) return false;
  return isIncompleteTimestampPrefix(visible);
}

export function stampOutput(value: string, continuingLine: boolean, now = new Date()): string {
  if (value.length === 0) return value;
  const stamp = formatTimestamp(now);
  const lines = value.split("\n");
  let isLineStart = !continuingLine;
  let result = "";
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (isLineStart && shouldStampLine(line)) {
      result += stamp;
    }
    result += line;
    if (index < lines.length - 1) result += "\n";
    isLineStart = true;
  }
  return result;
}

export function stampRunChunk(existing: string, chunk: string, now = new Date()): string {
  const continuingLine = existing.length > 0 && !existing.endsWith("\n");
  return stampOutput(chunk.replace(/\r/g, ""), continuingLine, now);
}

export interface OutputStamper {
  push(chunk: string, now?: Date): string;
  flush(now?: Date): string;
  reset(): void;
}

export function createOutputStamper(): OutputStamper {
  // Piped reads can split a line inside an ANSI sequence or an existing clock.
  // Hold that prefix until the next chunk makes the line classifiable.
  let pending = "";
  let atLineStart = true;

  const emitLine = (line: string, now: Date, withNewline: boolean): string => {
    const stamp = atLineStart && shouldStampLine(line) ? formatTimestamp(now) : "";
    atLineStart = withNewline;
    return `${stamp}${line}${withNewline ? "\n" : ""}`;
  };

  return {
    push(chunk, now = new Date()) {
      const value = `${pending}${chunk}`.replace(/\r/g, "");
      pending = "";
      if (value.length === 0) return "";
      const lines = value.split("\n");
      let result = "";
      const lastIndex = lines.length - 1;
      for (let index = 0; index < lastIndex; index += 1) {
        result += emitLine(lines[index], now, true);
      }
      if (value.endsWith("\n")) return result;
      const last = lines[lastIndex];
      if (atLineStart && isUndecidedPrefix(last)) {
        pending = last;
        return result;
      }
      return result + emitLine(last, now, false);
    },
    flush(now = new Date()) {
      if (pending.length === 0) return "";
      const line = pending;
      pending = "";
      return emitLine(line, now, false);
    },
    reset() {
      pending = "";
      atLineStart = true;
    },
  };
}

function controlSequenceEnd(text: string, escapeIndex: number): number | undefined {
  if (escapeIndex + 1 >= text.length) return undefined;
  const next = text.charCodeAt(escapeIndex + 1);
  if (next === 91) {
    for (let index = escapeIndex + 2; index < text.length; index += 1) {
      const code = text.charCodeAt(index);
      if (code >= 0x40 && code <= 0x7e) return index + 1;
    }
    return undefined;
  }
  if (next === 93) {
    for (let index = escapeIndex + 2; index < text.length; index += 1) {
      if (text.charCodeAt(index) === 7) return index + 1;
      if (text.charCodeAt(index) === 27 && text.charCodeAt(index + 1) === 92) return index + 2;
    }
    return undefined;
  }
  return escapeIndex + 2;
}

function advancePastIncompleteControl(text: string, start: number): number {
  if (start <= 0) return 0;
  const lookback = Math.max(0, start - 64);
  for (let index = start - 1; index >= lookback; index -= 1) {
    if (text.charCodeAt(index) !== 27) continue;
    const end = controlSequenceEnd(text, index);
    if (end === undefined || end > start) return end ?? text.length;
    break;
  }
  return start;
}

export function trimRunOutput(output: string, maximum: number): string {
  if (output.length <= maximum) return output;
  let start = output.length - maximum;
  const newline = output.indexOf("\n", start);
  if (newline !== -1) start = newline + 1;
  // A mid-sequence cut would leave `[31m` visible after the ESC is dropped.
  start = advancePastIncompleteControl(output, start);
  return output.slice(start);
}
