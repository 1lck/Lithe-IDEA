import { describe, expect, test } from "bun:test";
import { agentMentionQuery, removeAgentMention } from "./agent-composer-mentions";

describe("Agent composer file mentions", () => {
  test("opens on a bare trigger and keeps filtering while the user types", () => {
    expect(agentMentionQuery("@")).toEqual({ start: 0, query: "" });
    expect(agentMentionQuery("fix this @src/ma")).toEqual({ start: 9, query: "src/ma" });
    expect(agentMentionQuery("see\tthen @a")).toEqual({ start: 9, query: "a" });
  });

  test("stays closed for finished references, addresses and mid-word triggers", () => {
    expect(agentMentionQuery("mail me at user@example")).toBeNull();
    expect(agentMentionQuery("done @src/main.ts ")).toBeNull();
    expect(agentMentionQuery("no trigger here")).toBeNull();
    expect(agentMentionQuery("")).toBeNull();
  });

  test("removing the token leaves the rest of the draft intact", () => {
    const mention = agentMentionQuery("check @src/ma");
    if (mention === null) throw new Error("the helper must open the picker");
    expect(removeAgentMention("check @src/ma", mention)).toBe("check ");
    expect(removeAgentMention("@a", { start: 0, query: "a" })).toBe("");
    // A shorter draft than the match (user deleted text) is not over-sliced.
    expect(removeAgentMention("", { start: 0, query: "src" })).toBe("");
  });
});
