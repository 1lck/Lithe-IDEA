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
  return leadingTimeLength(line) !== undefined;
}

export function stampOutput(value: string, continuingLine: boolean, now = new Date()): string {
  if (value.length === 0) return value;
  const stamp = formatTimestamp(now);
  const lines = value.split("\n");
  let isLineStart = !continuingLine;
  let result = "";
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (isLineStart && line.length > 0 && !hasLeadingTime(line)) {
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
