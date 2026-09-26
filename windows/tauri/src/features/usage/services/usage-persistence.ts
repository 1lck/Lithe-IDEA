import { load, type Store } from "@tauri-apps/plugin-store";
import type { UsageLedger } from "./usage-ledger";

const USAGE_STORE_FILE = "usage-ledger.json";
const LEDGER_KEY = "ledger";

/**
 * A scan that found new requests would otherwise rewrite a multi-megabyte file
 * every couple of minutes. Throttling is safe: the offsets and the records are
 * written together, so a skipped write only means the next scan reads a little
 * more than it had to - and the duplicate records it produces are deduplicated.
 */
const MIN_WRITE_INTERVAL_MS = 60_000;

let storePromise: Promise<Store> | null = null;
let lastWriteAt = 0;
let scheduledFlush: number | null = null;

async function getStore(): Promise<Store> {
  if (!storePromise) {
    storePromise = load(USAGE_STORE_FILE, { autoSave: true } as Parameters<typeof load>[1]);
  }
  return storePromise;
}

/** Returns null when nothing was stored yet, which is the first run. */
export async function loadPersistedUsageLedger(): Promise<unknown> {
  try {
    const store = await getStore();
    const stored = await store.get(LEDGER_KEY);
    return stored ?? null;
  } catch {
    // An unreadable store costs a full rescan, not a broken feature.
    return null;
  }
}

function scheduleFlush(ledger: UsageLedger): void {
  if (scheduledFlush !== null) return;
  const delay = Math.max(0, MIN_WRITE_INTERVAL_MS - (Date.now() - lastWriteAt));
  scheduledFlush = window.setTimeout(() => {
    scheduledFlush = null;
    void persistUsageLedger(ledger);
  }, delay);
}

export async function persistUsageLedger(
  ledger: UsageLedger,
  options: { force?: boolean } = {},
): Promise<void> {
  if (!ledger.hasChanges()) return;

  if (!options.force && Date.now() - lastWriteAt < MIN_WRITE_INTERVAL_MS) {
    scheduleFlush(ledger);
    return;
  }

  try {
    const store = await getStore();
    await store.set(LEDGER_KEY, ledger.toStoredLedger());
    await store.save();
    ledger.markWritten();
    lastWriteAt = Date.now();
  } catch {
    // The ledger in memory is still correct; the next scan tries again.
  }
}
