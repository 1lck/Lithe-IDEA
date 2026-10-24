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
  processContents,
} from "./agent-transcript-items";

function message(
  id: string,
  role: AgentConversationMessage["role"],
  text: string,
  extra: Partial<AgentConversationMessage> = {},
): AgentConversationMessage {
  return { id, role, text, delivery: null, toolStatus: null, toolDetails: emptyToolDetails(), ...extra };
}

describe("Agent transcript grouping", () => {
  test("intermediate prose and tools form one process until the turn ends", () => {
    const messages = [
      message("u1", "user", "Fix it"),
      message("t1", "tool", "Read a.ts", { toolStatus: "completed" }),
      message("t2", "tool", "Edit a.ts", { toolStatus: "completed" }),
      message("a1", "agent", "Done"),
      message("t3", "tool", "Run tests", { toolStatus: "completed" }),
    ];
    const turn = finishTurn(startTurn("u1", 0), 1_000, "t3", null);
    const items = groupTranscript(messages, [turn]);
    expect(items.map((item) => item.id)).toEqual([
      "u1",
      "process:t1",
      "turn:u1",
    ]);
    // A turn ending in a tool has no final reply to copy.
    expect(items[items.length - 1]).toMatchObject({ kind: "turnSummary", reply: "" });
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

  test("reasoning is grouped separately from the reply and stays searchable", () => {
    const messages = [
      message("r1", "reasoning", "Read the manifest first"),
      message("a1", "agent", "Done"),
    ];
    const items = groupTranscript(messages);
    expect(items.map((item) => item.id)).toEqual(["process:r1", "a1"]);
    expect(itemMatches(items[0], "manifest")).toBe(true);
    expect(activitySummary(messages).tasks).toBe(0);
  });

  test("one process retains thought, narration and tool order without blank rows", () => {
    const messages = [
      message("u1", "user", "Explain"),
      message("r1", "reasoning", "Inspect the manifest"),
      message("a1", "agent", "I will read the project"),
      message("blank", "reasoning", " \n "),
      message("t1", "tool", "Read README"),
      message("t2", "tool", "Run tests"),
      message("r2", "reasoning", "Summarize the result"),
      message("a2", "agent", "This is a student management system"),
      message("empty", "agent", "\n"),
    ];
    const turn = finishTurn(startTurn("u1", 0), 1_000, "empty", null);
    const items = groupTranscript(messages, [turn]);
    expect(items.map((item) => item.id)).toEqual(["u1", "process:r1", "a2", "turn:u1"]);
    const process = items[1];
    if (process.kind !== "processGroup") throw new Error("Expected a process");
    expect(process.messages.map((entry) => entry.id)).toEqual(["r1", "a1", "t1", "t2", "r2"]);
    expect(processContents(process.messages).map((entry) => entry.id)).toEqual(["r1", "a1", "tools:t1", "r2"]);
    expect(itemMatches(process, "manifest")).toBe(true);
    expect(itemMatches(process, "student")).toBe(false);
    expect(items[3]).toMatchObject({ kind: "turnSummary", reply: "This is a student management system" });
    expect(groupTranscript(messages.slice(0, 3)).map((item) => item.id)).toEqual(["u1", "process:r1", "a1"]);
  });

  test("user prompts and recorded turn endings never merge separate processes", () => {
    const messages = [message("r1", "reasoning", "Inspect"), message("t1", "tool", "Read"),
      message("r2", "reasoning", "Continue"), message("a1", "agent", "Done"),
      message("u2", "user", "Next"), message("t2", "tool", "Read next")];
    const turn = finishTurn(startTurn("u1", 0), 1_000, "t1", null);
    expect(groupTranscript(messages, [turn]).map((item) => item.id)).toEqual([
      "process:r1", "turn:u1", "process:r2", "a1", "u2", "process:t2",
    ]);
    expect(groupTranscript([message("a1", "agent", "A direct answer")]).map((item) => item.id)).toEqual(["a1"]);
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
