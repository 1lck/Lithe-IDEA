import { describe, expect, test } from "bun:test";
import { partitionNewOccurrences } from "./notification-occurrences";

describe("notification occurrences", () => {
  test("counts a source once while it stays visible", () => {
    const first = partitionNewOccurrences(new Set(), ["toast-1", "toast-2"]);
    expect([...first.newIds]).toEqual(["toast-1", "toast-2"]);

    // Sonner re-reports every visible toast when another one appears; only the
    // genuinely new toast may be counted.
    const second = partitionNewOccurrences(first.reportedIds, ["toast-1", "toast-2", "toast-3"]);
    expect([...second.newIds]).toEqual(["toast-3"]);

    const third = partitionNewOccurrences(second.reportedIds, ["toast-1", "toast-2", "toast-3"]);
    expect([...third.newIds]).toEqual([]);
  });

  test("treats a source that disappeared and returned as a new occurrence", () => {
    const first = partitionNewOccurrences(new Set(), ["toast-1"]);
    const gone = partitionNewOccurrences(first.reportedIds, []);
    expect([...gone.newIds]).toEqual([]);
    expect([...gone.reportedIds]).toEqual([]);

    const returned = partitionNewOccurrences(gone.reportedIds, ["toast-1"]);
    expect([...returned.newIds]).toEqual(["toast-1"]);
  });
});
