import { debugSourcePathKey } from "../utils/debug-source-path";
import type { SourceModelChange } from "@lithe/editor/model-source";
import { invoke } from "@/platform/tauri-core";
import { logger } from "@/features/editor/utils/logger";
import { useDebuggerStore } from "../stores/debugger.store";

const MAX_PENDING_RELOCATIONS = 128;
const MAX_PENDING_SOURCE_BYTES = 32 * 1024 * 1024;
const MAX_PENDING_EDIT_BYTES = 32 * 1024 * 1024;
const MAX_BATCH_EDITS = 4096;
const MAX_USER_CHANGE_RETRIES = 4;
const EDIT_ACCOUNTING_OVERHEAD_BYTES = 64;
let pendingSourceBytes = 0;
let pendingEditBytes = 0;
const snapshots = new Map<string, { id: string; version: number; source: string }>();
let tail: Promise<void> | null = null;
let pending = 0;
let failureGeneration = -1;
let snapshotGeneration = -1;
let failure: unknown;
const seen = new WeakSet<SourceModelChange>();

type CoreBreakpoint = { line: number; enabled: boolean };
type CoreEdit = { startUtf16Offset: number; endUtf16Offset: number; replacement: string };
interface PendingRelocation {
  key: string;
  filePath: string;
  source: string;
  content: string;
  sourceBytes: number;
  editBytes: number;
  editCount: number;
  batches: CoreEdit[][];
  existingIds: Set<string>;
  revision: number;
  epoch: number;
  started: boolean;
}
let lastQueued: PendingRelocation | null = null;

/** Native editor changes are shared by split views and already ordered by SourceText. */
export function queueBreakpointRelocation(filePath: string, change: SourceModelChange): void {
  if (change.external || !change.changes.length || seen.has(change)) return;
  seen.add(change);
  const initial = useDebuggerStore.getState().actions.getBreakpointsForFile(filePath);
  if (!initial.length) return;
  // A breakpoint added after this edit already uses the new document's lines.
  const existingIds = new Set(initial.map(point => point.id));
  const state = useDebuggerStore.getState();
  const epoch = state.breakpointGeneration;
  const key = debugSourcePathKey(filePath);
  const revision = state.breakpointUserRevisions[key] ?? 0;
  if (failureGeneration !== epoch) failure = undefined;
  if (snapshotGeneration !== epoch) { snapshots.clear(); snapshotGeneration = epoch; }
  if (failure) return;
  const inputEdits = change.anchorChanges ?? change.changes;
  let editBytes = 0;
  for (const edit of inputEdits) {
    editBytes += edit.text.length * 2 + EDIT_ACCOUNTING_OVERHEAD_BYTES;
    if (pendingEditBytes + editBytes > MAX_PENDING_EDIT_BYTES) {
      failure = new Error("debugger.breakpointRelocationFailed");
      failureGeneration = epoch;
      logger.error("Debugger", "Breakpoint relocation queue limit reached");
      return;
    }
  }
  const edits = inputEdits.map(edit => ({
    startUtf16Offset: edit.offset, endUtf16Offset: edit.offset + edit.length, replacement: edit.text,
  }));
  const prior = lastQueued;
  const canAppend = prior && !prior.started && prior.key === key && prior.epoch === epoch &&
    prior.revision === revision && prior.content === change.previousContent &&
    prior.existingIds.size === existingIds.size && [...existingIds].every(id => prior.existingIds.has(id)) &&
    prior.editCount + edits.length <= MAX_BATCH_EDITS;
  const sourceBytes = change.previousContent.length * 2;
  if (pending >= MAX_PENDING_RELOCATIONS || pendingEditBytes + editBytes > MAX_PENDING_EDIT_BYTES ||
      (!canAppend && pendingSourceBytes + sourceBytes > MAX_PENDING_SOURCE_BYTES)) {
    failure = new Error("debugger.breakpointRelocationFailed");
    failureGeneration = epoch;
    logger.error("Debugger", "Breakpoint relocation queue limit reached");
    return;
  }
  pending++;
  pendingEditBytes += editBytes;
  if (canAppend) {
    prior.batches.push(edits);
    prior.content = change.content;
    prior.editBytes += editBytes;
    prior.editCount += edits.length;
    return;
  }
  const job: PendingRelocation = {
    key, filePath, source: change.previousContent, content: change.content, sourceBytes, editBytes,
    editCount: edits.length, batches: [edits], existingIds, revision, epoch, started: false,
  };
  pendingSourceBytes += sourceBytes;
  lastQueued = job;
  const operation = (tail ?? Promise.resolve()).then(async () => {
    job.started = true;
    pendingSourceBytes -= job.sourceBytes;
    if (lastQueued === job) lastQueued = null;
    if (job.epoch !== useDebuggerStore.getState().breakpointGeneration || failure) return;
    const cached = snapshots.get(job.key);
    const document = cached && cached.source === job.source
      ? { id: cached.id, version: cached.version + 1 }
      : { id: crypto.randomUUID(), version: 1 };
    for (let attempt = 0; attempt < MAX_USER_CHANGE_RETRIES; attempt++) {
      const state = useDebuggerStore.getState();
      const expected = state.actions.getBreakpointsForFile(job.filePath).filter(point => job.existingIds.has(point.id));
      if (!expected.length) return;
      const revision = state.breakpointUserRevisions[job.key] ?? 0;
      const result = await invoke<{ breakpoints: CoreBreakpoint[]; originalIndices: number[] }>("debug.relocateBreakpoints", {
        ...(attempt === 0
          ? { ...(document.version === 1 ? { source: job.source } : {}), document }
          : { source: job.source }),
        edits: job.batches[0],
        ...(job.batches.length > 1 ? { editBatches: job.batches.slice(1) } : {}),
        breakpoints: expected.map(point => ({ line: point.line + 1, enabled: point.enabled })),
      });
      if (attempt === 0) {
        snapshots.delete(job.key);
        if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
        snapshots.set(job.key, { ...document, source: job.content });
      }
      if (job.epoch !== useDebuggerStore.getState().breakpointGeneration) return;
      if ((useDebuggerStore.getState().breakpointUserRevisions[job.key] ?? 0) !== revision) continue;
      if (useDebuggerStore.getState().actions.applyRelocatedBreakpoints(job.filePath, expected, result.breakpoints, result.originalIndices)) return;
    }
    throw new Error("debugger.breakpointRelocationFailed");
  }).catch(error => {
    if (job.epoch !== useDebuggerStore.getState().breakpointGeneration) return;
    failure = error;
    failureGeneration = job.epoch;
    logger.error("Debugger", "Breakpoint relocation failed", error);
  }).finally(() => {
    pending -= job.batches.length;
    pendingEditBytes -= job.editBytes;
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
