import { describe, expect, test } from "bun:test";
import { decideWorkspaceDiagnostics } from "./diagnostics-retention";

const base = {
  isDocumentOpen: false,
  diagnosticCount: 1,
  isTracked: false,
  trackedFileCount: 0,
  maxTrackedFiles: 3,
};

describe("workspace diagnostics retention", () => {
  test("stores diagnostics for an unopened workspace file", () => {
    expect(decideWorkspaceDiagnostics(base)).toBe("store");
  });

  test("clears a tracked entry when the file becomes clean", () => {
    expect(
      decideWorkspaceDiagnostics({ ...base, diagnosticCount: 0, isTracked: true }),
    ).toBe("clear");
  });

  test("ignores a retraction for a file that was never tracked", () => {
    // Otherwise every clean file in the workspace would take a store row.
    expect(decideWorkspaceDiagnostics({ ...base, diagnosticCount: 0 })).toBe("ignore");
  });

  test("stops accepting new files at the limit", () => {
    expect(decideWorkspaceDiagnostics({ ...base, trackedFileCount: 3 })).toBe("ignore");
  });

  test("keeps updating files already tracked once the limit is reached", () => {
    // A tracked file must not get stuck showing stale markers.
    expect(
      decideWorkspaceDiagnostics({ ...base, trackedFileCount: 3, isTracked: true }),
    ).toBe("store");
  });

  test("clears a tracked file at the limit so the budget is released", () => {
    expect(
      decideWorkspaceDiagnostics({
        ...base,
        diagnosticCount: 0,
        isTracked: true,
        trackedFileCount: 3,
      }),
    ).toBe("clear");
  });

  test("never bounds an open document", () => {
    expect(
      decideWorkspaceDiagnostics({ ...base, isDocumentOpen: true, trackedFileCount: 99 }),
    ).toBe("store");
    expect(
      decideWorkspaceDiagnostics({
        ...base,
        isDocumentOpen: true,
        diagnosticCount: 0,
        trackedFileCount: 99,
      }),
    ).toBe("store");
  });
});
