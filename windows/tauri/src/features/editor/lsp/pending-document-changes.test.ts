import { describe, expect, test } from "bun:test";
import {
  flushLspDocumentChanges,
  hasLspDocumentChanges,
  queueLspDocumentChanges,
  registerLspDocumentChangeFlusher,
  takeLspDocumentChanges,
} from "./pending-document-changes";

describe("pending LSP document changes", () => {
  test("coalesces range changes until the debounce flush", () => {
    queueLspDocumentChanges("src/main.ts", [
      { rangeOffset: 0, rangeLength: 0, text: "a", startLine: 0, startColumn: 0, endLine: 0, endColumn: 0 },
    ]);
    queueLspDocumentChanges("src/main.ts", [
      { rangeOffset: 1, rangeLength: 0, text: "b", startLine: 0, startColumn: 1, endLine: 0, endColumn: 1 },
    ]);
    expect(hasLspDocumentChanges("src/main.ts")).toBe(true);
    expect(takeLspDocumentChanges("src/main.ts")).toHaveLength(2);
    expect(hasLspDocumentChanges("src/main.ts")).toBe(false);
  });
});

describe("request-time document flush", () => {
  test("resolves only after the registered flusher finished sending", async () => {
    const sequence: string[] = [];
    const unregister = registerLspDocumentChangeFlusher("src/main.php", async () => {
      sequence.push("flush");
      await Promise.resolve();
      sequence.push("sent");
    });

    await flushLspDocumentChanges("src/main.php");
    expect(sequence).toEqual(["flush", "sent"]);
    unregister();
  });

  test("is a no-op for a file whose owner is not registered", async () => {
    await expect(flushLspDocumentChanges("src/unopened.php")).resolves.toBeUndefined();
  });

  test("stops flushing a file once its owner unregisters", async () => {
    let flushes = 0;
    const unregister = registerLspDocumentChangeFlusher("src/main.php", async () => {
      flushes += 1;
    });

    unregister();
    await flushLspDocumentChanges("src/main.php");
    expect(flushes).toBe(0);
  });

  test("drains a replacement flusher registered while the old editor finishes", async () => {
    const path = "src/reopened.php";
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const first = registerLspDocumentChangeFlusher(path, () => gate);
    const events: string[] = [];
    const flushing = flushLspDocumentChanges(path);
    const second = registerLspDocumentChangeFlusher(path, async () => { events.push("restored"); });
    try {
      release(); await flushing;
      expect(events).toEqual(["restored"]);
    } finally {
      release(); await flushing; first(); second();
    }
  }, 1000);

  test("continuous owner replacement fails after three drains", async () => {
    const path = "src/churning.php";
    const unregister: Array<() => void> = [];
    let calls = 0;
    const replace = () => {
      unregister.push(registerLspDocumentChangeFlusher(path, async () => { calls += 1; replace(); }));
    };
    replace();
    try {
      await expect(flushLspDocumentChanges(path)).rejects.toThrow("ownership changed");
      expect(calls).toBe(3);
    } finally { for (const stop of unregister) stop(); }
  }, 1000);
});
