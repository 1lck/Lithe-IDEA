import { describe, expect, test } from "bun:test";
import type { AgentCommand } from "../types/agent.types";
import {
  commandInvocation,
  commandSuggestions,
  commandTrigger,
  completedCommandDraft,
  moveCommandHighlight,
  resolveCommandKey,
} from "./agent-command-completion";

const review: AgentCommand = { name: "review", description: "Review changes", hint: "focus" };
const compact: AgentCommand = {
  name: "compact",
  description: "Summarize the conversation",
  hint: null,
};
const skill: AgentCommand = { name: "$commit", description: "Commit changes", hint: null };
const commands = [review, compact, skill];

describe("Agent command triggers", () => {
  test("Chinese input methods map to the same lists", () => {
    expect(commandTrigger("/")).toBe("/");
    expect(commandTrigger("、")).toBe("/");
    expect(commandTrigger("$")).toBe("$");
    expect(commandTrigger("¥")).toBe("$");
    expect(commandTrigger("￥")).toBe("$");
    expect(commandTrigger("a")).toBeNull();
  });

  test("skills are invoked without the slash", () => {
    expect(commandInvocation(review)).toBe("/review");
    expect(commandInvocation(skill)).toBe("$commit");
    expect(completedCommandDraft(review)).toBe("/review ");
  });
});

describe("Agent command suggestions", () => {
  test("a slash lists every command and prefers prefix matches", () => {
    expect(commandSuggestions("/", commands)?.map((entry) => entry.name)).toEqual([
      "review",
      "compact",
      "$commit",
    ]);
    expect(commandSuggestions("/com", commands)?.map((entry) => entry.name)).toEqual([
      "compact",
      "$commit",
    ]);
    expect(commandSuggestions("/mmi", commands)?.map((entry) => entry.name)).toEqual(["$commit"]);
  });

  test("a dollar lists skills only, and only when the Agent advertises one", () => {
    expect(commandSuggestions("$", commands)?.map((entry) => entry.name)).toEqual(["$commit"]);
    expect(commandSuggestions("¥c", commands)?.map((entry) => entry.name)).toEqual(["$commit"]);
    expect(commandSuggestions("$", [review, compact])).toBeNull();
  });

  test("ordinary text, whitespace and path-like drafts are not intercepted", () => {
    expect(commandSuggestions("hello", commands)).toBeNull();
    expect(commandSuggestions("/review now", commands)).toBeNull();
    expect(commandSuggestions("C:/project", commands)).toBeNull();
  });

  test("the highlighted row wraps in both directions", () => {
    expect(moveCommandHighlight(0, -1, 3)).toBe(2);
    expect(moveCommandHighlight(2, 1, 3)).toBe(0);
    expect(moveCommandHighlight(9, 1, 3)).toBe(0);
    expect(moveCommandHighlight(0, 1, 0)).toBe(0);
  });
});

describe("Agent command keys", () => {
  const state = { highlightedIndex: 0, dismissed: false };

  test("Enter sends a fully typed command instead of completing it again", () => {
    expect(resolveCommandKey(state, "submit", "/review", [review, compact], false)).toEqual({
      kind: "send",
    });
    expect(resolveCommandKey(state, "submit", "please review", [review, compact], false)).toEqual({
      kind: "send",
    });
  });

  test("Enter and Tab complete the highlighted command", () => {
    expect(resolveCommandKey(state, "submit", "/rev", commands, false)).toMatchObject({
      kind: "complete",
      command: { name: "review" },
    });
    expect(resolveCommandKey(state, "tab", "/com", commands, false)).toMatchObject({
      kind: "complete",
      command: { name: "compact" },
    });
  });

  test("arrows move the highlight and Escape closes the list first", () => {
    expect(resolveCommandKey(state, "down", "/", commands, false)).toEqual({
      kind: "handled",
      state: { highlightedIndex: 1, dismissed: false },
    });
    expect(resolveCommandKey({ highlightedIndex: 2, dismissed: false }, "up", "/", commands, true)).toEqual({
      kind: "handled",
      state: { highlightedIndex: 1, dismissed: false },
    });
    expect(resolveCommandKey(state, "escape", "/", commands, true)).toEqual({
      kind: "handled",
      state: { highlightedIndex: 0, dismissed: true },
    });
    expect(resolveCommandKey(state, "escape", "hello", commands, true)).toEqual({
      kind: "cancel",
    });
    expect(resolveCommandKey(state, "escape", "hello", commands, false)).toEqual({
      kind: "ignored",
    });
    expect(resolveCommandKey({ highlightedIndex: 0, dismissed: true }, "down", "/", commands, false)).toEqual({
      kind: "ignored",
    });
  });
});