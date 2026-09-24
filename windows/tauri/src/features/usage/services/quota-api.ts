import { fetchPlatformQuota } from "./quota-client";
import type { PlatformQuota, QuotaConnectionKind, QuotaPlatformId } from "../types/quota.types";

export const QUOTA_PLATFORM_IDS: readonly QuotaPlatformId[] = ["claude", "codex"];

export const QUOTA_PLATFORM_LABEL_KEYS: Record<QuotaPlatformId, string> = {
  claude: "usage.platform.claude",
  codex: "usage.platform.codex",
};

export const QUOTA_CONNECTION_LABEL_KEYS: Record<QuotaConnectionKind, string> = {
  auth: "usage.connection.auth",
  api: "usage.connection.api",
  relay: "usage.connection.relay",
  none: "usage.connection.none",
};

export async function readQuotaSnapshot(): Promise<PlatformQuota[]> {
  return Promise.all(QUOTA_PLATFORM_IDS.map((platform) => fetchPlatformQuota(platform)));
}

export type QuotaSnapshotConsumer = (snapshot: PlatformQuota[]) => void;
export type QuotaSnapshotReader = () => Promise<PlatformQuota[]>;

/**
 * The platform a panel opens on: the one the user picked, otherwise the first
 * whose quota can actually be read, otherwise simply the first there is. The
 * shared entry points into the panel must agree on this.
 */
export function selectActiveQuota(
  snapshot: PlatformQuota[],
  selected: QuotaPlatformId | null,
): PlatformQuota | null {
  const queryable = snapshot.find((entry) => entry.connection === "auth");
  return snapshot.find((entry) => entry.platform === selected) ?? queryable ?? snapshot[0] ?? null;
}

/**
 * Same shape as `ApplicationMemoryPoller`: single-flight and stoppable.
 * A failure keeps the last successful result — writing a failure out as 0% is
 * the most misleading thing we could do.
 */
export class QuotaPoller {
  private active = false;
  private requestInFlight = false;

  constructor(
    private readonly consume: QuotaSnapshotConsumer,
    private readonly read: QuotaSnapshotReader = readQuotaSnapshot,
  ) {}

  start(): void {
    this.active = true;
  }

  stop(): void {
    this.active = false;
  }

  async poll(): Promise<void> {
    if (!this.active || this.requestInFlight) return;
    this.requestInFlight = true;
    try {
      const snapshot = await this.read();
      if (this.active) this.consume(snapshot);
    } catch {
      // Keep the last successful snapshot
    } finally {
      this.requestInFlight = false;
    }
  }
}
