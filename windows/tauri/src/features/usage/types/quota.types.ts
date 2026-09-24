export type QuotaPlatformId = "claude" | "codex";

/**
 * How this machine reaches the platform.
 *
 * - `auth`: official subscription (OAuth accessToken) — the only kind whose
 *   quota can be read from the official usage endpoint
 * - `api`: API key. The official endpoint only accepts OAuth tokens, so an API
 *   key gets a 401
 * - `relay`: custom relay address. Quota belongs to the relay; there is nothing
 *   local to query
 * - `none`: no configuration found
 */
export type QuotaConnectionKind = "auth" | "api" | "relay" | "none";

export interface QuotaWindow {
  /** Window id, also used as the badge text, e.g. `5h` / `7d` / `45m` */
  key: string;
  /** Used percentage 0–100; null means the source did not report it — never backfilled as 0 */
  usedPercent: number | null;
  /** ISO 8601; null means the source did not report it */
  resetsAt: string | null;
  /** Window length in seconds; null means the source did not report it */
  limitSeconds: number | null;
}

/**
 * Result state. `unsupported` and "invalid credential" are two different
 * things and the UI must keep them apart, otherwise API key users get pushed
 * towards signing in again.
 */
export type QuotaFailure =
  | "unsupported"
  | "unavailable"
  | "unauthorized"
  | "forbidden"
  | "rateLimited"
  | "timeout"
  | "network"
  | "unparsable";

export interface PlatformQuota {
  platform: QuotaPlatformId;
  connection: QuotaConnectionKind;
  windows: QuotaWindow[];
  /** null means the query succeeded */
  failure: QuotaFailure | null;
  /** Technical detail (HTTP status, raw parse error). Not translated, shown as-is. */
  detail: string | null;
  /** Local locations probed this time — listed in the UI rather than read silently */
  scannedPaths: string[];
  plan: string | null;
  fetchedAt: number | null;
}

export type TranslateFn = (key: string, values?: Record<string, string | number>) => string;
