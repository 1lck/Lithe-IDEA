import type {
  UsageCollection,
  UsageFileScanState,
  UsagePlatformId,
  UsageRecord,
  UsageRootScan,
} from "../types/usage.types";
import { dedupeKeyOf } from "./usage-aggregate";

/** Bumped when the stored shape changes. An older payload is dropped, not migrated. */
export const USAGE_LEDGER_VERSION = 1;

export interface UsageStoredLedger {
  version: number;
  records: UsageRecord[];
  scanState: Record<string, UsageFileScanState>;
}

export interface UsageLedgerSnapshot {
  records: UsageRecord[];
  roots: UsageRootScan[];
  /** When the last scan ran, or null if none has run in this session. */
  lastScanAt: number | null;
  /** Files the collector has a resume position for. */
  trackedFiles: number;
}

export interface UsageMergeResult {
  addedRecords: number;
  changedFiles: number;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function textOrNull(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/**
 * The stored file is one this app wrote, but it can be truncated by a crash or
 * edited by hand, and one bad token count would turn a total into NaN. Every
 * field is therefore normalized on the way in and an unusable record is dropped.
 */
function normalizeRecord(value: unknown): UsageRecord | null {
  if (!isPlainObject(value)) return null;
  const platform = value.platform;
  if (platform !== "claude" && platform !== "codex") return null;

  const dedupKey = textOrNull(value.dedupKey);
  if (dedupKey === null) return null;
  const ts = finiteOrNull(value.ts);
  if (ts === null) return null;

  return {
    platform: platform as UsagePlatformId,
    source: textOrNull(value.source) ?? "local-session",
    dedupKey,
    sessionId: textOrNull(value.sessionId),
    ts,
    model: textOrNull(value.model),
    inputTokens: finiteOrNull(value.inputTokens),
    outputTokens: finiteOrNull(value.outputTokens),
    cacheReadTokens: finiteOrNull(value.cacheReadTokens),
    cacheWriteTokens: finiteOrNull(value.cacheWriteTokens),
    totalTokens: finiteOrNull(value.totalTokens),
    effort: textOrNull(value.effort),
  };
}

function normalizeFileState(value: unknown): UsageFileScanState | null {
  if (!isPlainObject(value)) return null;
  const offset = finiteOrNull(value.offset);
  const modifiedMs = finiteOrNull(value.modifiedMs);
  if (offset === null || modifiedMs === null) return null;

  return {
    offset,
    modifiedMs,
    model: textOrNull(value.model),
    effort: textOrNull(value.effort),
  };
}

function sameFileState(left: UsageFileScanState, right: UsageFileScanState): boolean {
  return (
    left.offset === right.offset &&
    left.modifiedMs === right.modifiedMs &&
    left.model === right.model &&
    left.effort === right.effort
  );
}

/**
 * The records collected so far plus the resume position of every log file.
 *
 * The records are the reason this is persisted at all: a machine can hold more
 * than a gigabyte of session logs, so re-reading them to rebuild a week of usage
 * is not something to do on every start.
 */
export class UsageLedger {
  private readonly records: UsageRecord[] = [];
  private readonly seenKeys = new Set<string>();
  private readonly fileStates = new Map<string, UsageFileScanState>();
  private roots: UsageRootScan[] = [];
  private lastScanAt: number | null = null;
  private dirty = false;

  restore(payload: unknown): void {
    if (!isPlainObject(payload) || payload.version !== USAGE_LEDGER_VERSION) return;

    if (Array.isArray(payload.records)) {
      for (const candidate of payload.records) {
        const record = normalizeRecord(candidate);
        if (record === null) continue;
        const key = dedupeKeyOf(record);
        if (this.seenKeys.has(key)) continue;
        this.seenKeys.add(key);
        this.records.push(record);
      }
    }

    if (isPlainObject(payload.scanState)) {
      for (const [path, candidate] of Object.entries(payload.scanState)) {
        const state = normalizeFileState(candidate);
        if (state !== null) this.fileStates.set(path, state);
      }
    }
  }

  /** The resume positions to hand to the collector, keyed by absolute path. */
  fileState(): Record<string, UsageFileScanState> {
    return Object.fromEntries(this.fileStates);
  }

  /**
   * Folds one collection pass in.
   *
   * Deduplication happens here rather than in the collector because a file that
   * was rewritten is read again from the start, and because the state written
   * back is always a little older than the records in memory.
   */
  merge(collection: UsageCollection): UsageMergeResult {
    let changedFiles = 0;
    for (const file of collection.files) {
      const previous = this.fileStates.get(file.path);
      if (previous && sameFileState(previous, file.state)) continue;
      this.fileStates.set(file.path, file.state);
      changedFiles += 1;
    }

    let addedRecords = 0;
    for (const record of collection.records) {
      const key = dedupeKeyOf(record);
      if (this.seenKeys.has(key)) continue;
      this.seenKeys.add(key);
      this.records.push(record);
      addedRecords += 1;
    }

    if (collection.roots.length > 0) this.roots = collection.roots;
    this.lastScanAt = Date.now();
    if (addedRecords > 0 || changedFiles > 0) this.dirty = true;

    return { addedRecords, changedFiles };
  }

  snapshot(): UsageLedgerSnapshot {
    return {
      records: [...this.records],
      roots: this.roots,
      lastScanAt: this.lastScanAt,
      trackedFiles: this.fileStates.size,
    };
  }

  toStoredLedger(): UsageStoredLedger {
    return {
      version: USAGE_LEDGER_VERSION,
      records: this.records,
      scanState: this.fileState(),
    };
  }

  hasChanges(): boolean {
    return this.dirty;
  }

  markWritten(): void {
    this.dirty = false;
  }
}
