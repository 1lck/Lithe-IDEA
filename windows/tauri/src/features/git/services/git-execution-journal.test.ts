import policy from "../../../../../../shared/fixtures/git/execution-policy-v1.json";
import fixture from "../../../../../../shared/fixtures/git/execution-events-v1.json";
import type { GitExecutionEvent } from "@/platform/git-execution-events";
import { describe, expect, test } from "bun:test";
import { GitExecutionJournal, gitConsoleCommand } from "./git-execution-journal";

describe("Git execution journal", () => {
  test("authentication uses a separate queue and remote results survive completion", () => {
    const journal = new GitExecutionJournal();
    for (const event of fixture.events.slice(0, 2)) journal.receive(event as GitExecutionEvent);
    journal.receive(policy.authentication as GitExecutionEvent);
    expect(journal.authentication).toHaveLength(1);
    expect(journal.records[0].output).toBe("");
    journal.receive(policy.remoteResult as GitExecutionEvent);
    journal.receive({ operationId: "fixture", type: "requestFinished" });
    expect(journal.authentication).toHaveLength(0);
    expect(journal.records[0].remoteResult?.deletedReferences).toEqual(["refs/remotes/origin/old"]);
  });
  test("consumes the shared native event contract", () => {
    const journal = new GitExecutionJournal();
    for (const event of fixture.events) journal.receive(event as GitExecutionEvent);
    expect(journal.records).toHaveLength(1);
    expect(journal.records[0].state).toBe("completed");
    expect(journal.records[0].exitCode).toBe(0);
    expect(journal.active.size).toBe(0);
  });
  test("clearing an active operation suppresses its late events but permits a new operation", () => {
    const journal = new GitExecutionJournal();
    journal.receive({ operationId: "old", type: "requestStarted", workingDirectory: "C:/repo" });
    journal.receive({ operationId: "old", type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["fetch"] });
    journal.clear("C:/repo");
    journal.receive({ operationId: "old", type: "output", invocationId: 1, text: "late output" });
    journal.receive({ operationId: "old", type: "requestFinished" });
    expect(journal.records).toEqual([]);
    expect(journal.active.size).toBe(0);
    journal.receive({ operationId: "new", type: "requestStarted", workingDirectory: "C:/repo" });
    expect(journal.records).toHaveLength(1);
  });
  test("progress on stderr does not make a successful command fail", () => {
    const journal = new GitExecutionJournal();
    journal.receive({ operationId: "fetch", type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["fetch"] });
    journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stderr", text: "Receiving: 50%", progress: true });
    expect(journal.records[0].progress).toBe("Receiving: 50%");
    expect(journal.records[0].output).toBe("");
    journal.receive({ operationId: "fetch", type: "finished", invocationId: 1, exitCode: 0, durationMilliseconds: 42 });
    expect(journal.records[0].state).toBe("completed");
    expect(journal.records[0].error).toBeUndefined();
    expect(journal.records[0].durationMilliseconds).toBe(42);
  });
  test("output is bounded and preview formatting does not expose URL credentials", () => {
    const journal = new GitExecutionJournal();
    journal.receive({ operationId: "fetch", type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["fetch"] });
    journal.receive({ operationId: "fetch", type: "output", invocationId: 1, text: "x".repeat(100_000) });
    expect(journal.records[0].truncated).toBe(true);
    expect(journal.records[0].output.length).toBeLessThanOrEqual(65_536);
    expect(gitConsoleCommand(["fetch", "https://user:fake@example.invalid/repo"])).not.toContain("fake");
  });
});
