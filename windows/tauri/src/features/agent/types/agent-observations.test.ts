import { describe, expect, test } from "bun:test";
import { finishChildren, modelCallTotals, parseModelCall, updateChild, type AgentSubagent } from "./agent-observations";

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

  test("missing and malformed provider usage stays unknown in cumulative totals", () => {
    const known = parseModelCall({ api: "responses", status: 200, durationMs: 900, streaming: true,
      firstTokenMs: 100, usage: { inputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: 10 },
    })!;
    const unknown = parseModelCall({ api: "responses", status: 500, durationMs: 10, usage: { inputTokens: -1 } })!;
    expect(known.usage?.reasoningTokens).toBeNull();
    expect(unknown.usage).toBeNull();
    expect(modelCallTotals([known, unknown])).toMatchObject({ calls: 2, input: 20, cacheRead: 5, cacheWrite: 0, output: 10, lowerBound: true,
      durationMs: 910, latencyCount: 1, latencyMs: 100, generatingMs: 800, streamingOutput: 10, nonStreaming: 1 });
    expect(parseModelCall({ api: "responses", status: 200, durationMs: Infinity })).toBeNull();
  });

  test("auxiliary requests spend tokens but are not steps or latency samples", () => {
    const title = parseModelCall({ api: "anthropicMessages", status: 200, durationMs: 2000, streaming: true, firstTokenMs: 1900,
      auxiliary: true, usage: { inputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 16 } })!;
    const step = parseModelCall({ api: "anthropicMessages", status: 200, durationMs: 1000, streaming: true, firstTokenMs: 100,
      usage: { inputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 4 } })!;
    expect(title.auxiliary).toBe(true);
    expect(modelCallTotals([title, step])).toMatchObject({ calls: 1, input: 30, output: 20, durationMs: 1000,
      latencyCount: 1, latencyMs: 100, generatingMs: 900, streamingOutput: 4 });
  });
});
