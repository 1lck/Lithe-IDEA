import { leadingTimeLength } from "./output-timestamper";

export type OutputSeverity = "error" | "warning" | "info" | "debug";

export interface RunOutputSpan {
  text: string;
  className?: string;
  style?: {
    color?: string;
    backgroundColor?: string;
    fontWeight?: number;
  };
}

interface AnsiStyle {
  color?: string;
  background?: string;
  bold: boolean;
}

interface AnsiRange {
  start: number;
  end: number;
  style: AnsiStyle;
}

interface ParsedAnsi {
  text: string;
  ranges: AnsiRange[];
  hasStyling: boolean;
}

const SEVERITY_PATTERN = /(?:^|\s|\[)(ERROR|SEVERE|FATAL|WARN(?:ING)?|INFO|DEBUG|TRACE)(?:\]|\s|:)/;

const SEVERITY_CLASS: Record<OutputSeverity, string> = {
  error: "text-destructive",
  warning: "text-warning",
  info: "text-info",
  debug: "text-subtle-foreground",
};

const TIMESTAMP_CLASS = "text-subtle-foreground/70";

const ANSI_PALETTE = [
  "#0f1012",
  "#f16d75",
  "#4cc38a",
  "#d9a441",
  "#58a6e7",
  "#c8a2f4",
  "#61c0bf",
  "#c4c9d1",
  "#757d89",
  "#ff858d",
  "#68d5a0",
  "#edbb5c",
  "#75b9f0",
  "#dab9ff",
  "#7bd3d2",
  "#ffffff",
];

export function severityOfLine(line: string): OutputSeverity | undefined {
  const match = SEVERITY_PATTERN.exec(line);
  if (!match) return undefined;
  switch (match[1]) {
    case "ERROR":
    case "SEVERE":
    case "FATAL":
      return "error";
    case "WARN":
    case "WARNING":
      return "warning";
    case "INFO":
      return "info";
    case "DEBUG":
    case "TRACE":
      return "debug";
    default:
      return undefined;
  }
}

export function parseAnsi(source: string): ParsedAnsi {
  const ranges: AnsiRange[] = [];
  let text = "";
  let buffer = "";
  let style: AnsiStyle = { bold: false };
  let hasStyling = false;
  let index = 0;

  const flush = () => {
    if (buffer.length === 0) return;
    ranges.push({
      start: text.length,
      end: text.length + buffer.length,
      style: { ...style },
    });
    text += buffer;
    buffer = "";
  };

  while (index < source.length) {
    const code = source.charCodeAt(index);
    if (code === 27 && index + 1 < source.length) {
      const next = source[index + 1];
      if (next === "[") {
        flush();
        const sequence = readCsi(source, index);
        if (sequence.final === "m") {
          if (sequence.params !== "0" && sequence.params.length > 0) {
            hasStyling = true;
          }
          style = applySgr(sequence.params, style);
        }
        index = sequence.next;
        continue;
      }
      if (next === "]") {
        flush();
        index = skipOsc(source, index);
        continue;
      }
    }

    if (code === 8 || code === 127) {
      if (buffer.length > 0) buffer = buffer.slice(0, -1);
      index += 1;
      continue;
    }
    if (code === 13 || (code < 32 && code !== 9 && code !== 10)) {
      index += 1;
      continue;
    }

    buffer += source[index];
    index += 1;
  }
  flush();
  return { text, ranges, hasStyling };
}

export function renderRunOutput(source: string): RunOutputSpan[] {
  if (source.length === 0) return [];
  const parsed = parseAnsi(source);
  const spans: RunOutputSpan[] = [];
  let lineStart = 0;
  let rangeIndex = 0;

  const emit = (start: number, end: number, overlay: LineOverlay) => {
    if (start >= end) return;
    while (rangeIndex < parsed.ranges.length && parsed.ranges[rangeIndex].end <= start) {
      rangeIndex += 1;
    }
    let position = start;
    let index = rangeIndex;
    while (position < end && index < parsed.ranges.length) {
      const range = parsed.ranges[index];
      if (range.end <= position) {
        index += 1;
        continue;
      }
      if (range.start >= end) break;
      const sliceStart = Math.max(position, range.start);
      const sliceEnd = Math.min(end, range.end);
      if (sliceStart < sliceEnd) {
        pushSpan(spans, parsed.text.slice(sliceStart, sliceEnd), overlay, range.style, parsed.hasStyling);
        position = sliceEnd;
      }
      if (range.end <= end) index += 1;
      else break;
    }
  };

  while (lineStart < parsed.text.length) {
    const newline = parsed.text.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? parsed.text.length : newline;
    const line = parsed.text.slice(lineStart, lineEnd);
    const timeLength = leadingTimeLength(line) ?? 0;
    const severity = parsed.hasStyling ? undefined : severityOfLine(line);
    emit(lineStart, lineStart + timeLength, { kind: "timestamp" });
    emit(lineStart + timeLength, newline === -1 ? parsed.text.length : newline + 1, {
      kind: "body",
      severity,
    });
    if (newline === -1) break;
    lineStart = newline + 1;
  }

  return spans;
}

type LineOverlay =
  | { kind: "timestamp" }
  | { kind: "body"; severity?: OutputSeverity };

function pushSpan(
  spans: RunOutputSpan[],
  text: string,
  overlay: LineOverlay,
  style: AnsiStyle,
  hasStyling: boolean,
): void {
  if (text.length === 0) return;
  const span: RunOutputSpan = { text };
  if (overlay.kind === "timestamp") {
    span.className = TIMESTAMP_CLASS;
  } else if (hasStyling) {
    span.style = ansiStyle(style);
  } else if (overlay.severity) {
    span.className = SEVERITY_CLASS[overlay.severity];
  }
  if (span.style && Object.keys(span.style).length === 0) {
    delete span.style;
  }
  const previous = spans[spans.length - 1];
  if (previous && sameSpanStyle(previous, span)) {
    previous.text += text;
    return;
  }
  spans.push(span);
}

function sameSpanStyle(left: RunOutputSpan, right: RunOutputSpan): boolean {
  return (
    left.className === right.className &&
    left.style?.color === right.style?.color &&
    left.style?.backgroundColor === right.style?.backgroundColor &&
    left.style?.fontWeight === right.style?.fontWeight
  );
}

function ansiStyle(style: AnsiStyle): RunOutputSpan["style"] {
  const result: NonNullable<RunOutputSpan["style"]> = {};
  if (style.color) result.color = style.color;
  if (style.background) result.backgroundColor = style.background;
  if (style.bold) result.fontWeight = 700;
  return result;
}

function readCsi(source: string, start: number): { next: number; final: string; params: string } {
  let index = start + 2;
  while (index < source.length) {
    const code = source.charCodeAt(index);
    if (code >= 0x40 && code <= 0x7e) {
      return {
        next: index + 1,
        final: source[index],
        params: source.slice(start + 2, index),
      };
    }
    index += 1;
  }
  return { next: source.length, final: "", params: source.slice(start + 2) };
}

function skipOsc(source: string, start: number): number {
  let index = start + 2;
  while (index < source.length) {
    const code = source.charCodeAt(index);
    if (code === 7) return index + 1;
    if (code === 27 && source[index + 1] === "\\") return index + 2;
    index += 1;
  }
  return source.length;
}

function applySgr(parameters: string, current: AnsiStyle): AnsiStyle {
  const codes = parameters.length === 0 ? [0] : parameters.split(";").flatMap((part) => {
    if (part.length === 0) return [];
    const value = Number.parseInt(part, 10);
    return Number.isNaN(value) ? [] : [value];
  });
  let next: AnsiStyle = { ...current };
  let index = 0;
  while (index < codes.length) {
    const code = codes[index];
    if (code === 0) {
      next = { bold: false };
    } else if (code === 1) {
      next.bold = true;
    } else if (code === 22) {
      next.bold = false;
    } else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) {
      next.color = paletteColor(code);
    } else if (code === 39) {
      next.color = undefined;
    } else if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107)) {
      next.background = paletteColor(code - 10);
    } else if (code === 49) {
      next.background = undefined;
    } else if (code === 38 || code === 48) {
      const color = readExtendedColor(codes, index);
      if (color) {
        if (code === 38) next.color = color.value;
        else next.background = color.value;
        index += color.consumed;
      }
    }
    index += 1;
  }
  return next;
}

function readExtendedColor(
  codes: number[],
  index: number,
): { value: string; consumed: number } | undefined {
  if (index + 2 < codes.length && codes[index + 1] === 5) {
    return { value: color256(codes[index + 2]), consumed: 2 };
  }
  if (index + 4 < codes.length && codes[index + 1] === 2) {
    return {
      value: rgb(codes[index + 2], codes[index + 3], codes[index + 4]),
      consumed: 4,
    };
  }
  return undefined;
}

function paletteColor(code: number): string {
  if (code >= 90) return ANSI_PALETTE[(code - 90) % 8 + 8];
  return ANSI_PALETTE[(code - 30) % 8];
}

function color256(value: number): string {
  if (value < 16) return ANSI_PALETTE[value] ?? ANSI_PALETTE[7];
  if (value >= 232) {
    const component = 8 + (value - 232) * 10;
    return rgb(component, component, component);
  }
  const offset = value - 16;
  const red = Math.floor(offset / 36);
  const green = Math.floor(offset / 6) % 6;
  const blue = offset % 6;
  const channel = (level: number) => (level === 0 ? 0 : 40 * level + 55);
  return rgb(channel(red), channel(green), channel(blue));
}

function rgb(red: number, green: number, blue: number): string {
  return `rgb(${clampByte(red)}, ${clampByte(green)}, ${clampByte(blue)})`;
}

function clampByte(value: number): number {
  return Math.max(0, Math.min(255, value));
}
