import policy from "../../../../../../shared/fixtures/git/execution-policy-v1.json";
import fixture from "../../../../../../shared/fixtures/git/execution-events-v1.json";
import type { GitExecutionEvent } from "@/platform/git-execution-events";
import { describe, expect, test } from "bun:test";
import { GitExecutionJournal, gitConsoleCommand, gitConsoleConfiguration, gitConsoleTimestamp } from "./git-execution-journal";

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
    const timestamp = new Date(2026, 0, 1, 14, 9, 40, 880).getTime();
    const journal = new GitExecutionJournal(() => timestamp);
    for (const event of fixture.events) journal.receive(event as GitExecutionEvent);
    expect(journal.records).toHaveLength(1);
    expect(journal.records[0].state).toBe("completed");
    expect(journal.records[0].exitCode).toBe(0);
    expect(journal.active.size).toBe(0);
    expect(journal.records[0].timestamp).toBe(timestamp);
    expect(gitConsoleTimestamp(timestamp)).toBe("14:09:40.880");
    expect(journal.records[0].lines).toEqual([
      { stream: "stderr", text: "Receiving: 100%" },
      { stream: "stdout", text: "reference updated" },
    ]);
    expect(journal.records[0].output).toBe("Receiving: 100%\nreference updated\n");
  });
  test("empty output rows stay bounded without losing recent interleaved streams", () => {
    const journal = new GitExecutionJournal(() => 0);
    journal.receive({ operationId: "fetch", type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["fetch"] });
    for (let index = 0; index < 2_100; index++) {
      journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stdout", text: "" });
    }
    journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stderr", text: "remote response" });
    journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stdout", text: "updated reference" });
    expect(journal.records[0].truncated).toBe(true);
    expect(journal.records[0].lines).toHaveLength(2_000);
    expect(journal.records[0].output.endsWith("remote response\nupdated reference\n")).toBe(true);
  });
  test("expanded temporary configuration is quoted and credentials are redacted", () => {
    expect(gitConsoleConfiguration([["credential.helper", "helper with spaces"]])).toBe("-c 'credential.helper=helper with spaces'");
    const configuration = gitConsoleConfiguration([["http.proxy", "https://fixture:password@example.invalid/?token=fake-secret"]]);
    expect(configuration).toContain("redacted");
    expect(configuration).not.toContain("password");
    expect(configuration).not.toContain("fake-secret");
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
