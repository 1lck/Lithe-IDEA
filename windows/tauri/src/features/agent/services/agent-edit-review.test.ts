import { describe, expect, test } from "bun:test";
import { createConversation, upsertToolMessage } from "../types/agent.types";
import { agentFileChanges, canRevertAgentChange, reverseAgentChange } from "./agent-edit-review";

function transcript(updates: Record<string, unknown>[]) {
  return updates.reduce((conversation, update, index) => upsertToolMessage(conversation, String(index), {
    status: "completed", kind: "edit", ...update,
  }), createConversation()).messages;
}
const diff = (oldText: string | null, newText: string, operation?: string) => ({
  type: "diff", path: "sample.txt", oldText, newText, _meta: { kind: operation },
});

describe("Agent edit review", () => {
  test("reverses consecutive edits newest first without touching surrounding content", () => {
    const [change] = agentFileChanges(transcript([
      { content: [diff("one", "two")] }, { content: [diff("two", "three")] },
    ]));
    expect(reverseAgentChange(change, "before\nthree\nafter")).toBe("before\none\nafter");
  });
  test("reverses LF ACP edits against a CRLF Windows document", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff("before\n", "after\n")] }]));
    expect(reverseAgentChange(change, "before\r\nafter\r\n")).toBe("before\r\nbefore\r\n");
    expect(reverseAgentChange(change, "after\r\n")).toBe("before\r\n");
  });
  test("rejects ambiguous excerpts and external disk changes", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff("old", "new")] }]));
    expect(() => reverseAgentChange(change, "new new")).toThrow("agent.edits.changed");
    expect(() => reverseAgentChange(change, "unrelated")).toThrow("agent.edits.changed");
  });
  test("rejects overlapping exact excerpts instead of reverting the wrong occurrence", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff("x", "aba")] }]));
    expect(() => reverseAgentChange(change, "ababa")).toThrow("agent.edits.changed");
  });
  test("rejects overlapping excerpts after normalizing mixed line endings", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff("x", "a\nb\na")] }]));
    // Mixed LF/CRLF prevents an exact match; the canonical matches overlap.
    expect(() => reverseAgentChange(change, "a\nb\r\na\nb\r\na")).toThrow("agent.edits.changed");
  });
  test("an insertion with no original content is not proof of file creation", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff(null, "inserted")] }]));
    expect(canRevertAgentChange(change)).toBe(false);
  });
  test("creation can remove only the exact created content", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff(null, "created", "add")] }]));
    expect(reverseAgentChange(change, "created")).toBeNull();
    expect(() => reverseAgentChange(change, "created and edited")).toThrow();
  });
  test("deletion restores only to a still missing destination", () => {
    const [change] = agentFileChanges(transcript([{ kind: "delete", content: [diff("deleted", "", "delete")] }]));
    expect(reverseAgentChange(change, null)).toBe("deleted");
    expect(() => reverseAgentChange(change, "recreated")).toThrow();
  });
  test("pending, moved and truncated evidence cannot be reverted", () => {
    for (const update of [
      { status: "in_progress", content: [diff("old", "new")] },
      { kind: "move", content: [diff("old", "new")] },
      { content: [{ ...diff("old", "new"), isTruncated: true }] },
      { content: [diff("a".repeat(40_000), "new")] },
    ]) expect(canRevertAgentChange(agentFileChanges(transcript([update]))[0])).toBe(false);
  });
  test("failed and interrupted tool effects are excluded", () => {
    expect(agentFileChanges(transcript(["failed", "interrupted"].map((status) => ({ status, content: [diff("old", "new")] }))))).toEqual([]);
  });
  test("keeping an exact prefix preserves new edits and invalidates replaced evidence", () => {
    const first = { content: [diff("one", "two")] };
    const initial = agentFileChanges(transcript([first]))[0];
    const reviewed = { "sample.txt": initial.versions };
    expect(agentFileChanges(transcript([first]), reviewed)).toEqual([]);
    const [later] = agentFileChanges(transcript([first, { content: [diff("two", "three")] }]), reviewed);
    expect(later.diffs).toHaveLength(1);
    expect(reverseAgentChange(later, "three")).toBe("two");
    expect(agentFileChanges(transcript([{ content: [diff("one", "changed replay")] }]), reviewed)).toHaveLength(1);
  });
  test("Claude Write metadata replaces partial hunks with complete file evidence", () => {
    const [change] = agentFileChanges(transcript([{ content: [diff(null, "fragment")],
      _meta: { claudeCode: { toolName: "Write", toolResponse: { type: "create", filePath: "sample.txt", content: "whole\nfile\n" } } },
    }]));
    expect(reverseAgentChange(change, "whole\nfile\n")).toBeNull();
  });
});
