import { debugSourcePathKey } from "../utils/debug-source-path";
import type { SourceModelChange } from "@lithe/editor/model-source";
import { invoke } from "@/platform/tauri-core";
import { logger } from "@/features/editor/utils/logger";
import { useDebuggerStore } from "../stores/debugger.store";

const MAX_PENDING_RELOCATIONS = 128;
const MAX_PENDING_SOURCE_BYTES = 32 * 1024 * 1024;
let pendingSourceBytes = 0;
const snapshots = new Map<string, { id: string; version: number; source: string }>();
let tail: Promise<void> | null = null;
let pending = 0;
let failureGeneration = -1;
let snapshotGeneration = -1;
let failure: unknown;
const seen = new WeakSet<SourceModelChange>();

type CoreBreakpoint = { line: number; enabled: boolean };

/** Native editor changes are shared by split views and already ordered by SourceText. */
export function queueBreakpointRelocation(filePath: string, change: SourceModelChange): void {
  if (change.external || !change.changes.length || seen.has(change)) return;
  seen.add(change);
  if (!useDebuggerStore.getState().actions.getBreakpointsForFile(filePath).length) return;
  const userRevision = useDebuggerStore.getState().breakpointUserRevisions[debugSourcePathKey(filePath)] ?? 0;
  const epoch = useDebuggerStore.getState().breakpointGeneration;
  if (failureGeneration !== epoch) failure = undefined;
  if (snapshotGeneration !== epoch) { snapshots.clear(); snapshotGeneration = epoch; }
  if (failure) return;
  if (pending >= MAX_PENDING_RELOCATIONS || pendingSourceBytes + change.previousContent.length * 2 > MAX_PENDING_SOURCE_BYTES) {
    failure = new Error("debugger.breakpointRelocationFailed");
    failureGeneration = epoch;
    logger.error("Debugger", "Breakpoint relocation queue limit reached");
    return;
  }
  pending++;
  pendingSourceBytes += change.previousContent.length * 2;
  const operation = (tail ?? Promise.resolve()).then(async () => {
    if (epoch !== useDebuggerStore.getState().breakpointGeneration || failure) return;
    if ((useDebuggerStore.getState().breakpointUserRevisions[debugSourcePathKey(filePath)] ?? 0) !== userRevision) throw new Error("debugger.breakpointRelocationFailed");
    const expected = useDebuggerStore.getState().actions.getBreakpointsForFile(filePath);
    if (!expected.length) return;
    const key = debugSourcePathKey(filePath);
    const cached = snapshots.get(key);
    const document = cached && cached.source === change.previousContent
      ? { id: cached.id, version: cached.version + 1 }
      : { id: crypto.randomUUID(), version: 1 };
    const edits = (change.anchorChanges ?? change.changes).map(edit => ({
      startUtf16Offset: edit.offset, endUtf16Offset: edit.offset + edit.length, replacement: edit.text,
    }));
    const result = await invoke<{ breakpoints: CoreBreakpoint[] }>("debug.relocateBreakpoints", {
      ...(document.version === 1 ? { source: change.previousContent } : {}), document, edits,
      breakpoints: expected.map(point => ({ line: point.line + 1, enabled: point.enabled })),
    });
    snapshots.delete(key);
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
    snapshots.set(key, { ...document, source: change.content });
    const points = result.breakpoints;
    if ((useDebuggerStore.getState().breakpointUserRevisions[debugSourcePathKey(filePath)] ?? 0) !== userRevision) throw new Error("debugger.breakpointRelocationFailed");
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
    pendingSourceBytes -= change.previousContent.length * 2;
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
