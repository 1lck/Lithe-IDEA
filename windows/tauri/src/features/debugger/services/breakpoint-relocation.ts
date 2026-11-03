import type { SourceModelChange } from "@lithe/editor/model-source";
import { invoke } from "@/platform/tauri-core";
import { logger } from "@/features/editor/utils/logger";
import { useDebuggerStore } from "../stores/debugger.store";

const MAX_PENDING_RELOCATIONS = 128;
let tail: Promise<void> | null = null;
let pending = 0;
let failureGeneration = -1;
let failure: unknown;
const seen = new WeakSet<SourceModelChange>();

type CoreBreakpoint = { line: number; enabled: boolean };

/** Native editor changes are shared by split views and already ordered by SourceText. */
export function queueBreakpointRelocation(filePath: string, change: SourceModelChange): void {
  if (change.external || !change.changes.length || seen.has(change)) return;
  seen.add(change);
  if (!useDebuggerStore.getState().actions.getBreakpointsForFile(filePath).length) return;
  const epoch = useDebuggerStore.getState().breakpointGeneration;
  if (failureGeneration !== epoch) failure = undefined;
  if (failure) return;
  if (pending >= MAX_PENDING_RELOCATIONS) {
    failure = new Error("debugger.breakpointRelocationFailed");
    failureGeneration = epoch;
    logger.error("Debugger", "Breakpoint relocation queue limit reached");
    return;
  }
  pending++;
  const operation = (tail ?? Promise.resolve()).then(async () => {
    if (epoch !== useDebuggerStore.getState().breakpointGeneration || failure) return;
    const expected = useDebuggerStore.getState().actions.getBreakpointsForFile(filePath);
    if (!expected.length) return;
    let source = change.previousContent;
    let points: CoreBreakpoint[] = expected.map(point => ({ line: point.line + 1, enabled: point.enabled }));
    // SourceText emits ascending, original-source offsets. Replay from the end
    // without changing earlier offsets; Core owns all coordinate/anchor rules.
    const changes = change.anchorChanges ?? change.changes;
    for (let index = changes.length - 1; index >= 0; index--) {
      const edit = changes[index]!;
      const result = await invoke<{ breakpoints: CoreBreakpoint[] }>("debug.relocateBreakpoints", {
        source,
        edit: { startUtf16Offset: edit.offset, endUtf16Offset: edit.offset + edit.length, replacement: edit.text },
        breakpoints: points,
      });
      points = result.breakpoints;
      if (index > 0) {
        const result = await invoke<{ text: string }>("lsp.applyTextEdits", {
          text: source,
          edits: [{ range: {
            start: { line: edit.start.line, utf16Column: edit.start.column },
            end: { line: edit.end.line, utf16Column: edit.end.column },
          }, newText: edit.text }],
        });
        source = result.text;
      }
    }
    if (epoch !== useDebuggerStore.getState().breakpointGeneration) return;
    if (!useDebuggerStore.getState().actions.applyRelocatedBreakpoints(filePath, expected, points)) {
      throw new Error("debugger.breakpointRelocationFailed");
    }
  }).catch(error => {
    if (epoch !== useDebuggerStore.getState().breakpointGeneration) return;
    failure = error;
    failureGeneration = epoch;
    logger.error("Debugger", "Breakpoint relocation failed", error);
  }).finally(() => {
    pending--;
    if (tail === operation) tail = null;
  });
  tail = operation;
}

/** Never launch with a breakpoint snapshot captured before pending source edits. */
export async function flushBreakpointRelocations(): Promise<void> {
  while (tail) await tail;
  if (failureGeneration !== useDebuggerStore.getState().breakpointGeneration) failure = undefined;
  if (failure) {
    const [{ createTranslator }, { useSettingsStore }] = await Promise.all([
      import("@/i18n/locale"), import("@/features/settings/stores/settings.store"),
    ]);
    throw new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("debugger.breakpointRelocationFailed"), { cause: failure });
  }
}
