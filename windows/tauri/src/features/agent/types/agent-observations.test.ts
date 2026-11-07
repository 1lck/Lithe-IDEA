import { describe, expect, test } from "bun:test";
import statisticsFixture from "../../../../../../shared/fixtures/agent/model-call-statistics-v1.json";
import { finishChildren, latestContext, modelCallTotals, parseModelCall, updateChild, type AgentSubagent } from "./agent-observations";

const child = (id: string, parentID: string): AgentSubagent => ({
  id, parentID, name: id, task: "Inspect", state: "running", messages: [], plan: [], contextUsage: null,
});

describe("Agent observations", () => {
  test("finishing a subtree interrupts its tools and leaves sibling output live", () => {
    const tool = { sessionUpdate: "tool_call", toolCallId: "tool", title: "Inspect", status: "in_progress" };
    const parent = updateChild(child("parent", "root"), tool);
    const sibling = updateChild(child("sibling", "root"), tool);
    const result = finishChildren([parent, child("nested", "parent"), sibling], "parent");
    expect(result.map((entry) => entry.state)).toEqual(["disconnected", "disconnected", "running"]);
    expect(result[0].messages[0].toolStatus).toBe("interrupted");
    expect(result[2]).toBe(sibling);
    expect(updateChild(result[0], { sessionUpdate: "agent_message_chunk", content: { text: "late" } })).toBe(result[0]);
  });

  test("Host contributions sum to the shared totals", () => {
    for (const entry of statisticsFixture.cases) {
      const calls = entry.events.map((event) => parseModelCall(event.statistics)!);
      const total = entry.total as Record<string, unknown>;
      const expected = parseModelCall(total)!;
      expect(modelCallTotals(calls)).toEqual({
        calls: expected.steps, input: expected.inputTokens, cacheRead: expected.cacheReadTokens, cacheWrite: expected.cacheWriteTokens,
        output: expected.outputTokens, lowerBound: entry.events.some((event) => event.statistics.requests > event.statistics.callsWithUsage),
        durationMs: expected.durationMs, latencyMs: expected.firstTokenMs, latencyCount: expected.firstTokenCount,
        generatingMs: expected.generationMs, streamingOutput: expected.generatedTokens, nonStreaming: expected.nonStreamingSteps,
      });
      expect(latestContext(calls)).toEqual(expected.context);
    }
  });

  test("malformed contributions are dropped instead of guessed", () => {
    const valid = statisticsFixture.cases[0].events[0].statistics;
    expect(parseModelCall({ ...valid, steps: -1 })).toBeNull();
    expect(parseModelCall({ ...valid, durationMs: Infinity })).toBeNull();
    expect(parseModelCall({ api: "responses", status: 200, durationMs: 1 })).toBeNull();
  });
});
