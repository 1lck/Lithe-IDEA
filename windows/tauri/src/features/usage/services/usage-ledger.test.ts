import { describe, expect, test } from "bun:test";
import { USAGE_LEDGER_VERSION, UsageLedger } from "./usage-ledger";
import type { UsageCollection, UsageRecord } from "../types/usage.types";

function record(overrides: Partial<UsageRecord> & { dedupKey: string }): UsageRecord {
  return {
    platform: "claude",
    source: "local-session",
    sessionId: null,
    ts: 1_700_000_000_000,
    model: "claude-sonnet-4-5",
    inputTokens: 100,
    outputTokens: 10,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 110,
    effort: null,
    ...overrides,
  };
}

function collection(
  path: string,
  offset: number,
  records: UsageRecord[],
  status: UsageCollection["files"][number]["status"] = "appended",
): UsageCollection {
  return {
    records,
    files: [
      {
        path,
        status,
        bytesRead: 1,
        recordCount: records.length,
        state: { offset, modifiedMs: 5, model: null, effort: null },
      },
    ],
    roots: [
      { platform: "claude", directory: "C:\\home\\.claude\\projects", exists: true, fileCount: 1 },
    ],
    elapsedMs: 3,
  };
}

describe("merging a scan", () => {
  test("adds new records and remembers the resume position", () => {
    const ledger = new UsageLedger();

    const result = ledger.merge(collection("/logs/a.jsonl", 10, [record({ dedupKey: "one" })]));

    expect(result.addedRecords).toBe(1);
    expect(ledger.snapshot().records).toHaveLength(1);
    expect(ledger.fileState()["/logs/a.jsonl"]?.offset).toBe(10);
    expect(ledger.hasChanges()).toBe(true);
  });

  test("a rewritten file does not double count what was already seen", () => {
    const ledger = new UsageLedger();
    ledger.merge(collection("/logs/a.jsonl", 10, [record({ dedupKey: "one" })]));

    // The file was replaced, so the collector reads it from the start again and
    // reports the same request once more.
    const result = ledger.merge(
      collection(
        "/logs/a.jsonl",
        20,
        [record({ dedupKey: "one" }), record({ dedupKey: "two" })],
        "rewritten",
      ),
    );

    expect(result.addedRecords).toBe(1);
    expect(ledger.snapshot().records.map((entry) => entry.dedupKey)).toEqual(["one", "two"]);
  });

  test("the same id on another platform is a different request", () => {
    const ledger = new UsageLedger();
    ledger.merge(collection("/logs/a.jsonl", 10, [record({ dedupKey: "same" })]));

    const result = ledger.merge(
      collection("/logs/b.jsonl", 10, [record({ dedupKey: "same", platform: "codex" })]),
    );

    expect(result.addedRecords).toBe(1);
  });

  test("a scan that changed nothing leaves nothing to write", () => {
    const ledger = new UsageLedger();
    const pass = collection("/logs/a.jsonl", 10, [record({ dedupKey: "one" })], "unchanged");
    ledger.merge(pass);
    ledger.markWritten();

    const result = ledger.merge(pass);

    expect(result).toEqual({ addedRecords: 0, changedFiles: 0 });
    expect(ledger.hasChanges()).toBe(false);
  });
});

describe("restoring a stored ledger", () => {
  test("round trips the records and the resume positions", () => {
    const ledger = new UsageLedger();
    ledger.merge(collection("/logs/a.jsonl", 42, [record({ dedupKey: "one" })]));

    const restored = new UsageLedger();
    restored.restore(JSON.parse(JSON.stringify(ledger.toStoredLedger())));

    expect(restored.snapshot().records).toHaveLength(1);
    expect(restored.fileState()["/logs/a.jsonl"]?.offset).toBe(42);
  });

  test("an unusable payload is ignored instead of half trusted", () => {
    const restored = new UsageLedger();
    restored.restore({
      version: USAGE_LEDGER_VERSION - 1,
      records: [record({ dedupKey: "one" })],
      scanState: {},
    });
    restored.restore("not a ledger");
    restored.restore(null);

    expect(restored.snapshot().records).toHaveLength(0);
  });

  test("keeps usable records and drops the ones that would poison a total", () => {
    const restored = new UsageLedger();
    restored.restore({
      version: USAGE_LEDGER_VERSION,
      records: [
        record({ dedupKey: "good" }),
        // A truncated write can leave a record without its key or timestamp.
        { platform: "claude", ts: 1 },
        { platform: "claude", dedupKey: "no-ts" },
        { platform: "other", dedupKey: "other-platform", ts: 1 },
        { platform: "claude", dedupKey: "string-tokens", ts: 1, totalTokens: "12" },
      ],
      scanState: { "/logs/a.jsonl": { offset: "soon", modifiedMs: 1 } },
    });

    const records = restored.snapshot().records;
    expect(records.map((entry) => entry.dedupKey)).toEqual(["good", "string-tokens"]);
    // A token count that is not a number becomes "not reported", not NaN.
    expect(records[1]?.totalTokens).toBeNull();
    expect(restored.fileState()).toEqual({});
  });
});
