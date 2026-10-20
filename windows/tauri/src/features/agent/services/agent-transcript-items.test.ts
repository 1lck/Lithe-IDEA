import { describe, expect, test } from "bun:test";
import { emptyToolDetails, type AgentConversationMessage } from "../types/agent.types";
import { startTurn, finishTurn } from "../types/agent-turn-statistics";
import {
  activitySummary,
  groupTranscript,
  inlineSpans,
  itemMatches,
  messageSegments,
  provisionalTabTitle,
} from "./agent-transcript-items";

function message(
  id: string,
  role: AgentConversationMessage["role"],
  text: string,
  extra: Partial<AgentConversationMessage> = {},
): AgentConversationMessage {
  return { id, role, text, toolStatus: null, toolDetails: emptyToolDetails(), ...extra };
}

describe("Agent transcript grouping", () => {
  test("adjacent tools form one group and prose or a turn summary ends it", () => {
    const messages = [
      message("u1", "user", "Fix it"),
      message("t1", "tool", "Read a.ts", { toolStatus: "completed" }),
      message("t2", "tool", "Edit a.ts", { toolStatus: "completed" }),
      message("a1", "agent", "Done"),
      message("t3", "tool", "Run tests", { toolStatus: "completed" }),
    ];
    const turn = finishTurn(startTurn("u1", 0), 1_000, "t3", null);
    expect(groupTranscript(messages, [turn]).map((item) => item.id)).toEqual([
      "u1",
      "tools:t1",
      "a1",
      "tools:t3",
      "turn:u1",
    ]);
  });

  test("search matches tool evidence and never matches a turn summary", () => {
    const tool = message("t1", "tool", "Run command", {
      toolDetails: { ...emptyToolDetails(), output: "LITHE_TEST_PASSED" },
    });
    const [group] = groupTranscript([tool]);
    expect(itemMatches(group, "lithe_test")).toBe(true);
    expect(itemMatches(group, "missing")).toBe(false);
    const summary = groupTranscript(
      [message("u1", "user", "x")],
      [finishTurn(startTurn("u1", 0), 1, "u1", null)],
    )[1];
    expect(itemMatches(summary, "x")).toBe(false);
  });

  test("activity counts running tools and file changes", () => {
    const counts = activitySummary([
      message("t1", "tool", "a", { toolStatus: "pending" }),
      message("t2", "tool", "b", { toolStatus: "in_progress" }),
      message("t3", "tool", "c", {
        toolStatus: "failed",
        toolDetails: { ...emptyToolDetails(), kind: "edit" },
      }),
      message("a1", "agent", "reply"),
    ]);
    expect(counts).toEqual({ tasks: 3, running: 2, failed: 1, edits: 1 });
  });
});

describe("Agent message rendering", () => {
  test("splits prose and fenced code, keeping an unclosed fence as code", () => {
    expect(messageSegments("Intro\n```ts\nconst a = 1;\n```\nAfter\n```\nstreaming")).toEqual([
      { kind: "prose", text: "Intro" },
      { kind: "code", language: "ts", code: "const a = 1;" },
      { kind: "prose", text: "After" },
      { kind: "code", language: "", code: "streaming" },
    ]);
  });

  test("parses inline Markdown and leaves block syntax as text", () => {
    expect(inlineSpans("# Title with **bold**, `code` and [docs](https://example.com)")).toEqual([
      { kind: "text", text: "# Title with " },
      { kind: "strong", text: "bold" },
      { kind: "text", text: ", " },
      { kind: "code", text: "code" },
      { kind: "text", text: " and " },
      { kind: "link", text: "docs", href: "https://example.com" },
    ]);
  });

  test("a provisional tab title is the first line, cut at 40 characters", () => {
    expect(provisionalTabTitle("short\nsecond")).toBe("short");
    expect(provisionalTabTitle("x".repeat(45))).toBe(`${"x".repeat(40)}…`);
  });
});
