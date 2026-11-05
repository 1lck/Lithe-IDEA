import { getLargeContentLineText, getLineSlice } from "./large-file";
import type { Range } from "../types/editor.types";

const MOUNT_RETRY_LIMIT = 10;
const MOUNT_RETRY_DELAY_MS = 150;

export interface ResolveGoToLineTargetOptions {
  content: string;
  lineNumber: number;
  columnNumber?: number;
  lineCount: number;
  lineOffsets?: readonly number[];
}

export interface GoToLineTarget {
  line: number;
  column: number;
  offset: number;
  lineStartOffset: number;
  lineLength: number;
}

/** The Core decision selects content only, never the line terminator. */
export function goToLineSelection(target: GoToLineTarget, selectsWholeLine: boolean): Range | undefined {
  if (!selectsWholeLine) return undefined;
  return {
    start: { line: target.line, column: 0, offset: target.lineStartOffset },
    end: { line: target.line, column: target.lineLength, offset: target.lineStartOffset + target.lineLength },
  };
}

/** Own bounded retries while a newly opened editor mounts; newer targets win. */
export function createGoToLineRetry<T>(
  apply: (target: T) => boolean,
  schedule: (callback: () => void, delay: number) => ReturnType<typeof setTimeout> = setTimeout,
  cancelTimer: (timer: ReturnType<typeof setTimeout>) => void = clearTimeout,
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let generation = 0;
  const cancel = () => {
    generation++;
    if (timer !== undefined) cancelTimer(timer);
    timer = undefined;
  };
  return {
    start(target: T) {
      cancel();
      const request = generation;
      let attempts = 0;
      const attempt = () => {
        if (generation !== request) return;
        timer = undefined;
        if (apply(target)) return;
        attempts++;
        if (attempts < MOUNT_RETRY_LIMIT) timer = schedule(attempt, MOUNT_RETRY_DELAY_MS);
      };
      attempt();
    },
    dispose: cancel,
  };
}

export function resolveGoToLineTarget({
  content,
  lineNumber,
  columnNumber,
  lineCount,
  lineOffsets,
}: ResolveGoToLineTargetOptions): GoToLineTarget {
  const targetLine = Math.max(0, Math.min(lineNumber - 1, Math.max(0, lineCount - 1)));
  const targetLineOffset = lineOffsets?.[targetLine];
  const targetLineSlice =
    targetLineOffset != null && lineOffsets
      ? {
          line: getLargeContentLineText(content, lineOffsets, targetLine),
          offset: targetLineOffset,
        }
      : getLineSlice(content, targetLine);
  const column = Math.max(0, Math.min((columnNumber ?? 1) - 1, targetLineSlice.line.length));

  return {
    line: targetLine,
    column,
    offset: targetLineSlice.offset + column,
    lineStartOffset: targetLineSlice.offset,
    lineLength: targetLineSlice.line.length,
  };
}
