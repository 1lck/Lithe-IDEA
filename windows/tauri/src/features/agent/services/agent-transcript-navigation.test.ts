import { describe, expect, test } from "bun:test";
import type { AgentConversationMessage } from "../types/agent.types";
import { transcriptNavigation } from "./agent-transcript-navigation";

function message(
  id: string,
  role: AgentConversationMessage["role"],
  text: string,
): AgentConversationMessage {
  return {
    id,
    role,
    text,
    delivery: null,
    toolStatus: null,
    toolDetails: { kind: null, input: null, output: null, locations: [], content: [] },
  };
}

describe("Agent transcript navigation", () => {
  test("tools and reasoning belong to the preceding prompt", () => {
    const navigation = transcriptNavigation([
      message("u1", "user", "First task"),
      message("r1", "reasoning", "thinking"),
      message("t1", "tool", "read file"),
      message("a1", "agent", "First answer"),
      message("u2", "user", "Second task"),
      message("a2", "agent", "Second answer"),
    ]);

    expect(navigation.entries).toEqual([
      { id: "u1", prompt: "First task", reply: "First answer" },
      { id: "u2", prompt: "Second task", reply: "Second answer" },
    ]);
    expect(navigation.turnByMessageID).toEqual({
      u1: "u1",
      r1: "u1",
      t1: "u1",
      a1: "u1",
      u2: "u2",
      a2: "u2",
    });
  });

  test("the latest Agent prose becomes the preview and history before the first prompt is skipped", () => {
    const navigation = transcriptNavigation([
      message("orphan", "agent", "Replayed greeting"),
      message("u1", "user", "Task"),
      message("a1", "agent", "Working on it"),
      message("a2", "agent", "Done"),
    ]);
    expect(navigation.entries).toEqual([{ id: "u1", prompt: "Task", reply: "Done" }]);
    expect(navigation.turnByMessageID.orphan).toBeUndefined();
  });

  test("prompt and reply previews are bounded like macOS", () => {
    const navigation = transcriptNavigation([
      message("u1", "user", "p".repeat(400)),
      message("a1", "agent", "  " + "r".repeat(700)),
    ]);
    expect(navigation.entries[0].prompt).toHaveLength(320);
    // The 640-character prefix is trimmed, exactly like macOS.
    expect(navigation.entries[0].reply).toBe("r".repeat(638));
  });
});