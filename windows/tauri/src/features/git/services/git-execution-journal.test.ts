import policy from "../../../../../../shared/fixtures/git/execution-policy-v1.json";
import fixture from "../../../../../../shared/fixtures/git/execution-events-v1.json";
import lifecycle from "../../../../../../shared/fixtures/git/console-lifecycle-v1.json";
import type { GitExecutionEvent } from "@/platform/git-execution-events";
import { describe, expect, test } from "bun:test";
import { GitExecutionJournal, gitConsoleCommand, gitConsoleConfiguration, gitConsoleTimestamp } from "./git-execution-journal";

describe("Git execution journal", () => {
  test("shared lifecycle keeps preflight silent and suppresses cleared requests", () => {
    for (const sample of lifecycle.cases) {
      const journal = new GitExecutionJournal(() => 0);
      for (const raw of sample.steps) {
        const step = raw as { clear?: boolean; event?: GitExecutionEvent; commands: string[][]; running: string[] };
        if (step.clear) journal.clear();
        if (step.event) journal.receive(step.event);
        expect(journal.records.map((record) => record.arguments)).toEqual(step.commands);
        for (const operationId of step.running) expect(journal.active.has(operationId)).toBe(true);
        if (step.event?.type === "requestFinished") expect(journal.active.has(step.event.operationId)).toBe(false);
      }
      expect(journal.active.size).toBe(0);
    }
  });
  test("silent queries never consume or evict the full visible command history", () => {
    const journal = new GitExecutionJournal(() => 0);
    for (let index = 0; index < 200; index++) {
      const operationId = `command-${index}`;
      journal.receive({ operationId, type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["commit"] });
      journal.receive({ operationId, type: "finished", invocationId: 1, exitCode: 0 });
      journal.receive({ operationId, type: "requestFinished" });
    }
    const retained = journal.records;
    const originalIds = retained.map((record) => record.id);
    for (const operationId of ["status", "references", "worktrees"]) {
      journal.receive({ operationId, type: "requestStarted", workingDirectory: "C:/repo" });
      expect(journal.active.has(operationId)).toBe(true);
      expect(journal.records.map((record) => record.id)).toEqual(originalIds);
    }
    for (const operationId of ["status", "references", "worktrees"]) journal.receive({ operationId, type: "requestFinished" });
    expect(journal.records).toBe(retained);
    expect(journal.historyTruncated).toBe(false);
    expect(journal.active.size).toBe(0);
  });
  test("failed preflight retains its reason and directory without claiming Git started", () => {
    const journal = new GitExecutionJournal(() => 0);
    for (let index = 0; index < 201; index++) {
      const operationId = `failed-${index}`;
      journal.receive({ operationId, type: "requestStarted", workingDirectory: "C:/denied", action: "git_fetch" });
      journal.receive({ operationId, type: "requestFinished", error: { message: "Could not open repository", details: "Permission denied" } });
    }
    expect(journal.records).toHaveLength(200);
    expect(journal.records[199]).toMatchObject({ root: "C:/denied", action: "git_fetch", arguments: [], state: "unconfirmed",
      error: "Could not open repository\nPermission denied" });
    expect(journal.records[199]!.exitCode).toBeUndefined();
    expect(journal.historyTruncated).toBe(true);
    expect(journal.active.size).toBe(0);
  });
  test("all operation sources share history before a console subscribes", () => {
    const journal = new GitExecutionJournal(() => 0);
    for (const command of ["add", "commit", "checkout", "push", "stash", "rebase", "worktree"]) {
      journal.receive({ operationId: command, type: "requestStarted", workingDirectory: "C:/repo" });
      journal.receive({ operationId: command, type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: [command] });
    }
    for (const command of ["push", "add", "commit", "checkout", "stash", "rebase", "worktree"]) {
      journal.receive({ operationId: command, type: "output", invocationId: 1, stream: "stdout", text: command });
      journal.receive({ operationId: command, type: "finished", invocationId: 1, exitCode: 0 });
      journal.receive({ operationId: command, type: "requestFinished" });
    }
    expect(journal.records.map((record) => record.arguments[0])).toEqual(["add", "commit", "checkout", "push", "stash", "rebase", "worktree"]);
    expect(journal.records.every((record) => record.output === record.arguments[0] + "\n" && record.state === "completed")).toBe(true);
    journal.receive({ operationId: "query", type: "requestStarted", workingDirectory: "C:/repo" });
    journal.receive({ operationId: "query", type: "requestFinished" });
    expect(journal.records).toHaveLength(7);
    expect(journal.active.size).toBe(0);
  });
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
    expect(journal.records).toEqual([]);
    journal.receive({ operationId: "new", type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["fetch"] });
    expect(journal.records).toHaveLength(1);
    journal.receive({ operationId: "new", type: "requestFinished" });
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
  test("project console keeps worktree operations together and clears all checkout paths", () => {
    const journal = new GitExecutionJournal(() => 0);
    for (const [operationId, root, action] of [["main", "C:/repo", "add"], ["linked", "C:/linked", "repair"]]) {
      journal.receive({ operationId, type: "requestStarted", workingDirectory: root });
      journal.receive({ operationId, type: "started", invocationId: 1, workingDirectory: root, arguments: ["worktree", action] });
    }
    expect(journal.records.map((record) => record.root)).toEqual(["C:/repo", "C:/linked"]);
    journal.clear();
    for (const operationId of ["main", "linked"]) {
      journal.receive({ operationId, type: "output", invocationId: 1, text: "late output" });
      journal.receive({ operationId, type: "requestFinished" });
    }
    expect(journal.records).toEqual([]);
    expect(journal.active.size).toBe(0);
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


test("discarded execution history is marked separately from foldable retained output", () => {
  const journal = new GitExecutionJournal(() => 0);
  for (let index = 0; index < 205; index += 1) {
    journal.receive({ operationId: `query-${index}`, type: "started", invocationId: 1, workingDirectory: "C:/repo", arguments: ["status"] });
  }
  expect(journal.records).toHaveLength(200);
  expect(journal.historyTruncated).toBe(true);
  journal.clear("C:/repo");
  expect(journal.historyTruncated).toBe(false);
});
