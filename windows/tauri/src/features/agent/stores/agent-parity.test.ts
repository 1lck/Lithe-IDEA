import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/acp-events-v1.json";
import { AgentConnectionModel } from "./agent-connection.model";
import type { AgentTransport } from "../services/agent-transport";
import type { AgentSessionStatistics } from "../types/agent-session-statistics";

describe("Agent parity lifecycle", () => {
  let model: AgentConnectionModel;
  let deliver: (event: unknown) => void;
  let commands: Record<string, unknown>[];
  let statistics: Map<string, AgentSessionStatistics>;
  let now: number;
  const command = (kind: string) => commands.filter((entry) => entry.kind === kind).slice(-1)[0]!;
  const view = () => model.getSnapshot().conversations["session-1"];
  const update = (value: Record<string, unknown>, sessionId = "session-1") => deliver({ kind: "update", sessionId, update: value });
  const options = (selected = "example-model") => [
    { ...fixture.events.sessionConfigured.configOptions[0], currentValue: selected,
      options: [{ value: "example-model", name: "Original" }, { value: "other", name: "Other" }] },
    fixture.events.sessionConfigured.configOptions[2],
  ];

  beforeEach(async () => {
    commands = [];
    now = 1000;
    statistics = new Map();
    const transport: AgentTransport = {
      open: async (_id, _launch, onEvent) => {
        deliver = onEvent;
        return { send: async (value) => { commands.push(value as Record<string, unknown>); }, close: async () => {} };
      },
    };
    model = new AgentConnectionModel(transport, { schedule: (flush) => flush(), cancel() {} }, () => now, undefined, {
      read: (id) => statistics.get(id) ?? null,
      write: (id, record) => { statistics.set(id, record); },
    });
    await model.connect({ agentId: "claude-acp", command: null, args: [], cwd: "C:/sample", dataDirectory: "C:/data", authentication: "apiKey", provider: null });
    deliver({ ...fixture.events.ready, canListArchivedSessions: true, canSteer: true });
    model.startNewConversation();
    deliver({ ...fixture.events.sessionCreated, token: command("newSession").token, configOptions: options() });
  });
  afterEach(async () => { await model.stop(); });

  test("successful empty history is reused for 30 seconds and manual refresh bypasses it", () => {
    deliver({ kind: "sessions", token: command("listSessions").token, sessions: [] });
    deliver({ kind: "archivedSessions", token: command("listArchivedSessions").token, sessions: [] });
    const count = commands.length;
    now += 29_999;
    model.refreshSessions();
    model.refreshArchivedSessions();
    expect(commands).toHaveLength(count);
    model.refreshSessions(true);
    expect(commands).toHaveLength(count + 1);
    model.refreshSessions(true);
    expect(commands).toHaveLength(count + 1);
    deliver({ kind: "sessions", token: command("listSessions").token, sessions: [] });
    now += 1;
    model.refreshArchivedSessions();
    expect(commands).toHaveLength(count + 2);
  });

  for (const responseAfterTurn of [false, true]) {
    test(`a completed turn invalidates only active history (responseAfterTurn=${responseAfterTurn})`, () => {
      const active = { kind: "sessions", token: command("listSessions").token, sessions: [] };
      deliver({ kind: "archivedSessions", token: command("listArchivedSessions").token, sessions: [] });
      if (!responseAfterTurn) deliver(active);
      model.send("Update recency");
      now += 100;
      deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
      if (responseAfterTurn) deliver(active);
      const count = commands.length;
      model.refreshSessions();
      model.refreshArchivedSessions();
      expect(commands).toHaveLength(count + 1);
      expect(commands[commands.length - 1]?.kind).toBe("listSessions");
      deliver({ kind: "sessions", token: command("listSessions").token, sessions: [] });
      model.refreshSessions();
      expect(commands).toHaveLength(count + 1);
    });
  }

  test("tool totals count unique calls and overlapping activity once, excluding replay", () => {
    model.send("Inspect tools");
    update({ sessionUpdate: "tool_call", toolCallId: "one", title: "First", status: "in_progress" });
    now = 1100;
    update({ sessionUpdate: "tool_call", toolCallId: "two", title: "Second", status: "in_progress" });
    now = 1200;
    update({ sessionUpdate: "tool_call_update", toolCallId: "one", status: "completed" });
    now = 1400;
    update({ sessionUpdate: "tool_call_update", toolCallId: "two", status: "completed" });
    now = 1500;
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(view().statistics.toolCallCount).toBe(2);
    expect(view().statistics.toolDurationMs).toBe(400);
    update({ sessionUpdate: "tool_call_update", toolCallId: "one", status: "completed" });
    expect(statistics.get("session-1")?.toolCallCount).toBe(2);
    model.send("Next");
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(view().statistics.toolCallCount).toBe(2);
    expect(view().statistics.toolDurationMs).toBe(400);
  });

  for (const archiveFirst of [true, false]) {
    test(`archive ownership wins with archiveFirst=${archiveFirst}`, () => {
      const sessions = [{ sessionId: "old", title: "Archived" }, { sessionId: "active", title: "Active" }];
      const active = { kind: "sessions", token: command("listSessions").token, sessions };
      const archive = { kind: "archivedSessions", token: command("listArchivedSessions").token, sessions: [sessions[0]], complete: false };
      deliver(archiveFirst ? archive : active);
      deliver(archiveFirst ? active : archive);
      expect(model.getSnapshot().sessions.map((item) => item.id)).not.toContain("old");
      expect(model.getSnapshot().sessions.map((item) => item.id)).toContain("active");
      expect(model.getSnapshot().archivedSessions.map((item) => item.id)).toEqual(["old"]);
      expect(model.getSnapshot().archivedHistoryComplete).toBe(false);
    });
  }

  test("restore supersedes stale scans and only opens on confirmation", async () => {
    const oldToken = command("listArchivedSessions").token;
    deliver({ kind: "archivedSessions", token: oldToken, sessions: [{ sessionId: "old", title: "Archived" }] });
    const result = model.unarchiveSession("old");
    expect(model.getSnapshot().selectedSessionID).toBe("session-1");
    deliver({ kind: "sessionUnarchived", token: command("unarchiveSession").token, sessionId: "old" });
    expect(await result).toBe(true);
    deliver({ kind: "archivedSessions", token: oldToken, sessions: [{ sessionId: "old" }] });
    expect(model.getSnapshot().archivedSessions).toEqual([]);
    expect(model.getSnapshot().selectedSessionID).toBe("old");
    expect(command("loadSession").sessionId).toBe("old");
  });

  for (const disconnected of [false, true]) {
    test(`failed restore resolves without changing selection (disconnect=${disconnected})`, async () => {
      deliver({ kind: "archivedSessions", token: command("listArchivedSessions").token, sessions: [{ sessionId: "old" }] });
      const result = model.unarchiveSession("old");
      if (disconnected) await model.stop();
      else deliver({ kind: "requestFailed", token: command("unarchiveSession").token, sessionId: "old", message: "Restore refused" });
      expect(await result).toBe(false);
      expect(model.getSnapshot().selectedSessionID).not.toBe("old");
      expect(model.getSnapshot().unarchivingSessionIDs).toEqual([]);
    });
  }

  test("subtree completion clears child permissions while preserving root and sibling", () => {
    model.send("Inspect");
    deliver(fixture.events.subagentSpawned);
    deliver(fixture.events.nestedSubagentSpawned);
    update({ sessionUpdate: "subagent_spawned", subagentSessionId: "sibling", name: "Sibling" });
    for (const owner of ["session-1", "child-1", "child-2", "sibling"]) {
      deliver({ kind: "permission", sessionId: "session-1", requestId: owner, request: { sessionId: owner, options: [] } });
    }
    deliver(fixture.events.subagentMessageChunk);
    expect(view().subagents[0].messages).toHaveLength(1);
    deliver(fixture.events.subagentStateUpdate);
    expect(view().pendingPermissions.map((item) => item.id)).toEqual(["session-1", "sibling"]);
    expect(view().subagents.map((child) => child.state)).toEqual(["completed", "disconnected", "running"]);
    deliver(fixture.events.subagentMessageChunk);
    deliver({ kind: "permission", sessionId: "session-1", requestId: "late", request: { sessionId: "child-2", options: [] } });
    expect(view().subagents[0].messages).toHaveLength(1);
    expect(view().pendingPermissions).toHaveLength(2);
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(view().subagents[2].state).toBe("disconnected");
    expect(view().pendingPermissions).toEqual([]);
  });

  for (const nextTurn of [false, true]) {
    test(`completed child history cannot block new child permissions (nextTurn=${nextTurn})`, () => {
      model.send("Inspect many tasks");
      for (let index = 0; index < 70; index++) {
        const id = `completed-${index}`;
        update({ sessionUpdate: "subagent_spawned", subagentSessionId: id });
        update({ sessionUpdate: "subagent_state_update", subagentSessionId: id, state: "completed" });
      }
      if (nextTurn) {
        deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
        model.send("Continue inspection");
      }
      update({ sessionUpdate: "subagent_spawned", subagentSessionId: "live-child" });
      deliver({ kind: "permission", sessionId: "session-1", requestId: "live-permission", request: { sessionId: "live-child", options: [] } });
      expect(view().pendingPermissions.map((prompt) => prompt.id)).toEqual(["live-permission"]);
      expect(view().subagents.find((child) => child.id === "live-child")?.state).toBe("running");
      expect(view().subagents.filter((child) => child.state !== "running")).toHaveLength(64);
      expect(view().subagents.some((child) => child.id === "completed-0")).toBe(false);
    });
  }

  test("more than 64 active children retain permission ownership until they terminate", () => {
    model.send("Inspect concurrent tasks");
    for (let index = 0; index < 70; index++) {
      const id = `active-${index}`;
      update({ sessionUpdate: "subagent_spawned", subagentSessionId: id });
      deliver({ kind: "permission", sessionId: "session-1", requestId: id, request: { sessionId: id, options: [] } });
    }
    expect(view().subagents).toHaveLength(70);
    expect(view().pendingPermissions).toHaveLength(70);
    update({ sessionUpdate: "subagent_state_update", subagentSessionId: "active-69", state: "completed" });
    expect(view().pendingPermissions).toHaveLength(69);
    expect(view().pendingPermissions.some((prompt) => prompt.id === "active-69")).toBe(false);
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(view().subagents).toHaveLength(64);
    expect(view().pendingPermissions).toEqual([]);
  });

  test("unannounced child traffic cannot become a root conversation", () => {
    deliver(fixture.events.subagentMessageChunk);
    expect(model.getSnapshot().conversations["child-1"]).toBeUndefined();
  });

  test("review acknowledgements survive disconnect and replay, then expire when the tab closes", async () => {
    model.send("Review this change");
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    model.acknowledgeEdits("session-1", "file.txt", ["version-one"]);
    const original = view().reviewedEdits;
    await model.stop();
    expect(view().reviewedEdits).toEqual(original);
    await model.connect({ agentId: "claude-acp", command: null, args: [], cwd: "C:/sample", dataDirectory: "C:/data", authentication: "apiKey", provider: null });
    deliver(fixture.events.ready);
    model.selectSession("session-1");
    expect(command("loadSession").sessionId).toBe("session-1");
    expect(view().reviewedEdits).toEqual(original);
    deliver({ kind: "sessionLoaded", token: command("loadSession").token, sessionId: "session-1", configOptions: options() });
    expect(view().reviewedEdits).toEqual(original);
    model.closeConversation("session-1");
    expect(model.getSnapshot().conversations["session-1"]).toBeUndefined();
    model.selectSession("session-1");
    expect(view().reviewedEdits).toBeUndefined();
  });

  test("next-turn settings apply model first, wait for each ACK, then continue", () => {
    model.send("First turn");
    model.setConfigOption("reasoning_effort", "high");
    model.setConfigOption("model", "other");
    model.send("Continue");
    deliver({ ...fixture.events.steeringResult, token: command("steer").token, outcome: "promptRequired" });
    expect(commands.filter((item) => item.kind === "setConfigOption")).toHaveLength(0);
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(command("setConfigOption").configId).toBe("model");
    expect(commands.filter((item) => item.kind === "prompt")).toHaveLength(1);
    deliver({ kind: "sessionConfigured", token: command("setConfigOption").token, sessionId: "session-1", configOptions: options("other") });
    expect(command("setConfigOption").configId).toBe("reasoning_effort");
    deliver({ kind: "sessionConfigured", token: command("setConfigOption").token, sessionId: "session-1", configOptions: options("other").map((item) => item.id === "reasoning_effort" ? { ...item, currentValue: "high" } : item) });
    expect(command("prompt").text).toBe("Continue");
    expect(view().stagedConfig).toEqual({});
  });

  test("configuration rejection preserves confirmed value and fails the queued continuation", () => {
    model.send("First turn");
    model.setConfigOption("model", "other");
    model.send("Continue");
    deliver({ ...fixture.events.steeringResult, token: command("steer").token, outcome: "promptRequired" });
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    deliver({ kind: "requestFailed", token: command("setConfigOption").token, sessionId: "session-1", message: "Not available" });
    expect(view().configOptions[0].currentValue).toBe("example-model");
    expect(view().pendingConfigToken).toBeNull();
    expect(command("prompt").text).toBe("First turn");
    expect(view().messages.slice(-1)[0]?.delivery).toEqual({ failed: "Not available" });
    expect(model.getSnapshot().hasPendingContinuation).toBe(false);
  });

  test("activity clears retry indicators and retired retries cannot contaminate a later turn", () => {
    model.send("First turn");
    deliver(fixture.events.turnActivityQuiet);
    deliver(fixture.events.turnRetrying);
    expect(view().quiet).toBe(true);
    expect(view().retry?.attempt).toBe(2);
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Reply" } });
    expect(view().quiet).toBe(false);
    expect(view().retry).toBeNull();
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    model.send("Second turn");
    deliver(fixture.events.turnRetrying);
    expect(view().retry).toBeNull();
  });

  test("removing an obsolete Claude fallback keeps unrelated warnings", () => {
    const mode = { id: "mode", name: "Mode", category: "mode", type: "select", currentValue: "acceptEdits", options: [{ value: "acceptEdits", name: "Edits" }, { value: "auto", name: "Auto" }] };
    update({ sessionUpdate: "config_option_update", configOptions: [...options(), mode] });
    update({ sessionUpdate: "notice", severity: "warning", title: "Auto mode unavailable" });
    update({ sessionUpdate: "notice", severity: "warning", title: "Independent warning" });
    update({ sessionUpdate: "current_mode_update", currentModeId: "auto" });
    expect(view().notices.map((item) => item.title)).toEqual(["Independent warning"]);
  });

  test("late model calls contribute to the session without changing the next turn", () => {
    model.send("First turn");
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    model.send("Second turn");
    deliver({ kind: "modelCall", sessionId: "session-1", afterTurnFinished: true, call: { api: "messages", model: "test", status: 200, streaming: false, durationMs: 12 } });
    expect(view().modelCalls).toHaveLength(1);
    expect(view().modelCalls[0].usage).toBeNull();
    expect(view().activeTurn?.modelCalls).toEqual([]);
  });

  test("durable statistics survive closing and loading without counting history replay", () => {
    model.send("Count once");
    deliver({ kind: "modelCall", sessionId: "session-1", call: { api: "messages", status: 200, streaming: true, durationMs: 900, firstTokenMs: 100,
      usage: { inputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: 10 } } });
    deliver(fixture.events.turnFinishedWithUsage);
    const saved = statistics.get("session-1")!;
    expect(saved.turnCount).toBe(1);
    expect(saved.calls.calls).toBe(1);
    model.closeConversation("session-1");
    model.selectSession("session-1");
    update({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "Count once" } });
    // Even if a peer replays observations, loading must never charge them twice.
    deliver({ kind: "modelCall", sessionId: "session-1", call: { api: "messages", status: 200, durationMs: 900 } });
    deliver({ kind: "sessionLoaded", token: command("loadSession").token, sessionId: "session-1", configOptions: options() });
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(view().statistics).toEqual(saved);
    model.send("Next");
    deliver({ kind: "turnFinished", sessionId: "session-1", stopReason: "end_turn" });
    expect(statistics.get("session-1")!.turnCount).toBe(2);
    expect(statistics.get("session-1")!.latestUsage).toEqual(saved.latestUsage);
    expect(statistics.get("session-1")!.calls).toEqual(saved.calls);
  });
});
