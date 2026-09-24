import { homeDir, join } from "@tauri-apps/api/path";
import { invoke } from "@/platform/tauri-core";
import type { UsageCollection, UsagePlatformId } from "../types/usage.types";
import type { UsageLedger, UsageLedgerSnapshot } from "./usage-ledger";
import { persistUsageLedger } from "./usage-persistence";

export interface UsageRootDefinition {
  platform: UsagePlatformId;
  directory: string;
}

/** Where each CLI keeps its session logs, relative to the home directory. */
const USAGE_LOG_DIRECTORIES: ReadonlyArray<{
  platform: UsagePlatformId;
  segments: readonly string[];
}> = [
  { platform: "claude", segments: [".claude", "projects"] },
  { platform: "codex", segments: [".codex", "sessions"] },
];

export async function resolveUsageRoots(): Promise<UsageRootDefinition[]> {
  let home: string;
  try {
    home = await homeDir();
  } catch {
    return [];
  }
  if (!home) return [];

  return Promise.all(
    USAGE_LOG_DIRECTORIES.map(async ({ platform, segments }) => ({
      platform,
      directory: await join(home, ...segments),
    })),
  );
}

/** Reads the session logs on the Rust side, which is where the bytes are. */
export async function collectUsage(ledger: UsageLedger): Promise<UsageCollection> {
  return invoke<UsageCollection>("usage_collect", {
    request: {
      roots: await resolveUsageRoots(),
      known: ledger.fileState(),
    },
  });
}

export type UsageSnapshotConsumer = (snapshot: UsageLedgerSnapshot) => void;

/**
 * Same shape as `QuotaPoller`: single-flight and stoppable.
 *
 * A scan that found nothing new is not published, so a panel left open does not
 * recompute its aggregates every interval for no reason.
 */
export class UsageScanner {
  private active = false;
  private scanInFlight = false;
  private hasPublished = false;

  constructor(
    private readonly ledger: UsageLedger,
    private readonly consume: UsageSnapshotConsumer,
  ) {}

  start(): void {
    this.active = true;
  }

  stop(): void {
    this.active = false;
  }

  async scan(): Promise<void> {
    if (!this.active || this.scanInFlight) return;
    this.scanInFlight = true;
    try {
      const collection = await collectUsage(this.ledger);
      const { addedRecords, changedFiles } = this.ledger.merge(collection);

      if (this.active && (!this.hasPublished || addedRecords > 0 || changedFiles > 0)) {
        this.hasPublished = true;
        this.consume(this.ledger.snapshot());
      }

      await persistUsageLedger(this.ledger);
    } catch {
      // Keep what the ledger already holds - an empty panel would read as
      // "you used nothing today", which is the most misleading answer here.
    } finally {
      this.scanInFlight = false;
    }
  }
}
