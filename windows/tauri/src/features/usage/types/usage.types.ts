export type UsagePlatformId = "claude" | "codex";

/**
 * One request worth of usage.
 *
 * Every token field is nullable on purpose: a source that does not report a
 * number reports nothing at all rather than zero, because zero reads as "this
 * request was free".
 */
export interface UsageRecord {
  platform: UsagePlatformId;
  /** `local-session` for the CLI logs; a future ingest path uses its own value. */
  source: string;
  /** Dedup key: Claude uses `message.id`, Codex uses `response_id`. */
  dedupKey: string;
  sessionId: string | null;
  /** UTC milliseconds */
  ts: number;
  model: string | null;
  inputTokens: number | null;
  outputTokens: number | null;
  cacheReadTokens: number | null;
  cacheWriteTokens: number | null;
  /** Total tokens: the source's own figure when it has one, otherwise that source's own arithmetic. */
  totalTokens: number | null;
  /**
   * Reasoning effort (low / medium / high and so on), passed through as it is.
   * Claude states it on the assistant line; Codex states it on a context line,
   * so it is inherited per session.
   */
  effort: string | null;
}

/** Where the previous scan stopped in one file, plus the context Codex keeps on separate lines. */
export interface UsageFileScanState {
  offset: number;
  modifiedMs: number;
  model: string | null;
  effort: string | null;
}

export type UsageFileStatus = "appended" | "rewritten" | "unchanged" | "failed";

export interface UsageFileScan {
  path: string;
  state: UsageFileScanState;
  status: UsageFileStatus;
  bytesRead: number;
  recordCount: number;
}

export interface UsageRootScan {
  platform: UsagePlatformId;
  directory: string;
  exists: boolean;
  fileCount: number;
}

/** What one collection pass read and parsed; the Rust collector's wire shape. */
export interface UsageCollection {
  records: UsageRecord[];
  files: UsageFileScan[];
  roots: UsageRootScan[];
  elapsedMs: number;
}

export interface UsageTotals {
  requests: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalTokens: number;
  /** Estimated cost of the records that could be priced, in US dollars. */
  costUsd: number;
  /**
   * Records that could not be priced. The UI has to mark the cost as an
   * estimate whenever this is not zero - and the priced total must not be
   * thrown away just because a few records could not be priced.
   */
  unpricedRequests: number;
}

export type UsageRangeId = "today" | "week" | "month" | "total";

export interface UsageRangeTotals {
  range: UsageRangeId;
  /** Half-open interval [start, end), UTC milliseconds. */
  start: number;
  end: number;
  totals: UsageTotals;
}

export type UsageBucketUnit = "hour" | "day";

export interface UsageBucket {
  /** Bucket start, UTC milliseconds. */
  start: number;
  totals: UsageTotals;
}
