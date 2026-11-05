import { describe, expect, test } from "bun:test";
import evidenceFixture from "../../../../../../shared/fixtures/agent/edit-review-v1.json";
import { createConversation, upsertToolMessage } from "../types/agent.types";
import { agentFileChanges, agentReversePlanRequest, canRevertAgentChange } from "./agent-edit-review";

type Evidence = { path: string; oldText: string | null; newText: string; operation: string | null; truncated: boolean; revertible: boolean };

/** Host-presented tool update: raw ACP diff plus the Host's `_meta.lithe.diffs`. */
function hostDiff(oldText: string | null, newText: string, options: { operation?: string; truncated?: boolean } = {}) {
  const truncated = options.truncated ?? false;
  const evidence: Evidence = { path: "sample.txt", oldText, newText, operation: options.operation ?? null, truncated,
    revertible: !truncated && (oldText !== null || options.operation === "add") };
  return { content: [{ type: "diff", path: "sample.txt", oldText, newText }], _meta: { lithe: { diffs: [evidence] } } };
}

function transcript(updates: Record<string, unknown>[]) {
  return updates.reduce((conversation, update, index) => upsertToolMessage(conversation, String(index), {
    status: "completed", kind: "edit", ...update,
  }), createConversation()).messages;
}

/** Expands the shared fixture's `{repeat, count, suffix?}` text generators. */
function expand(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(expand);
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (typeof object.repeat === "string" && typeof object.count === "number") {
      return object.repeat.repeat(object.count) + (typeof object.suffix === "string" ? object.suffix : "");
    }
    return Object.fromEntries(Object.entries(object).map(([key, entry]) => [key, expand(entry)]));
  }
  return value;
}

describe("Agent edit review", () => {
  test("stores Host evidence verbatim without recounting UTF-16 units", () => {
    for (const entry of evidenceFixture.evidence) {
      const expected = expand(entry.expected) as Evidence[] | null;
      if (expected === null) continue;
      const update = expand(entry.update) as Record<string, unknown>;
      const meta = (update._meta ?? {}) as Record<string, unknown>;
      const [message] = transcript([{ ...update, _meta: { ...meta, lithe: { diffs: expected } } }]);
      const diffs = message.role === "tool" ? message.toolDetails.diffs ?? [] : [];
      expect(diffs.map((diff) => [diff.newText, diff.oldText, diff.incomplete, diff.revertible]))
        .toEqual(expected.map((diff) => [diff.newText, diff.oldText, diff.truncated, diff.revertible]));
    }
  });
  test("raw ACP diff content without Host evidence is display-only", () => {
    const [message] = transcript([{ content: [{ type: "diff", path: "sample.txt", oldText: "a", newText: "b" }] }]);
    expect(message.role === "tool" ? message.toolDetails.diffs ?? [] : null).toEqual([]);
  });
  test("builds the shared reverse plan request in execution order with tool kinds", () => {
    const [change] = agentFileChanges(transcript([
      { content: hostDiff("one", "two").content, _meta: hostDiff("one", "two")._meta },
      { kind: "delete", ...hostDiff("two", "") },
    ]));
    expect(agentReversePlanRequest(change, "two")).toEqual({
      diffs: [
        { oldText: "one", newText: "two", operation: null, toolKind: "edit", truncated: false },
        { oldText: "two", newText: "", operation: null, toolKind: "delete", truncated: false },
      ],
      pending: false,
      missingEvidence: false,
      disk: "two",
    });
  });
  test("an insertion with no original content is not proof of file creation", () => {
    expect(canRevertAgentChange(agentFileChanges(transcript([hostDiff(null, "inserted")]))[0])).toBe(false);
    expect(canRevertAgentChange(agentFileChanges(transcript([hostDiff(null, "created", { operation: "add" })]))[0])).toBe(true);
  });
  test("pending, moved and truncated evidence cannot be reverted", () => {
    for (const update of [
      { status: "in_progress", ...hostDiff("old", "new") },
      { kind: "move", ...hostDiff("old", "new") },
      hostDiff("old", "new", { truncated: true }),
    ]) expect(canRevertAgentChange(agentFileChanges(transcript([update]))[0])).toBe(false);
    const [moved] = agentFileChanges(transcript([{ kind: "move", ...hostDiff("old", "new") }]));
    expect(agentReversePlanRequest(moved, "new").missingEvidence).toBe(true);
  });
  test("failed and interrupted tool effects are excluded", () => {
    expect(agentFileChanges(transcript(["failed", "interrupted"].map((status) => ({ status, ...hostDiff("old", "new") }))))).toEqual([]);
  });
  test("keeping an exact prefix preserves new edits and invalidates replaced evidence", () => {
    const first = hostDiff("one", "two");
    const initial = agentFileChanges(transcript([first]))[0];
    const reviewed = { "sample.txt": initial.versions };
    expect(agentFileChanges(transcript([first]), reviewed)).toEqual([]);
    const [later] = agentFileChanges(transcript([first, hostDiff("two", "three")]), reviewed);
    expect(later.diffs.map((diff) => diff.oldText)).toEqual(["two"]);
    expect(agentFileChanges(transcript([hostDiff("one", "changed replay")]), reviewed)).toHaveLength(1);
  });
  test("an update without Host evidence keeps earlier evidence", () => {
    const [change] = agentFileChanges(transcript([hostDiff("one", "two")]).map((message) =>
      message.role === "tool" ? upsertToolMessage({ ...createConversation(), messages: [message] }, "0", { rawOutput: "saved" }).messages[0] : message));
    expect(change.diffs.map((diff) => diff.newText)).toEqual(["two"]);
  });
});
