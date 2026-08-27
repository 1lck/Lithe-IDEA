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
