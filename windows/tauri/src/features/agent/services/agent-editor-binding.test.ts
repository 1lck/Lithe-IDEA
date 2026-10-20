import { describe, expect, test } from "bun:test";
import { editorAgentSessionIDs, resolveAgentEditorBinding } from "./agent-editor-binding";

describe("Agent editor binding", () => {
  test("the tool window follows the shared selection", () => {
    expect(
      resolveAgentEditorBinding({
        isEditor: false,
        boundSessionID: "bound-session",
        boundAgentID: "codex-acp",
        activeAgentID: "claude-acp",
        selectedSessionID: "selected-session",
      }),
    ).toEqual({ sessionID: "selected-session", isForeignAgent: false });
  });

  test("an editor tab reads its own session instead of another pane's selection", () => {
    expect(
      resolveAgentEditorBinding({
        isEditor: true,
        boundSessionID: "bound-session",
        boundAgentID: "codex-acp",
        activeAgentID: "codex-acp",
        selectedSessionID: "selected-session",
      }),
    ).toEqual({ sessionID: "bound-session", isForeignAgent: false });
  });

  test("a tab from another Agent is not attached to the current connection", () => {
    expect(
      resolveAgentEditorBinding({
        isEditor: true,
        boundSessionID: "bound-session",
        boundAgentID: "codex-acp",
        activeAgentID: "claude-acp",
        selectedSessionID: "bound-session",
      }),
    ).toEqual({ sessionID: "bound-session", isForeignAgent: true });
  });

  test("an older tab without an Agent owner stays usable", () => {
    expect(
      resolveAgentEditorBinding({
        isEditor: true,
        boundSessionID: "bound-session",
        boundAgentID: "",
        activeAgentID: "claude-acp",
        selectedSessionID: null,
      }),
    ).toEqual({ sessionID: "bound-session", isForeignAgent: false });
  });
});


describe("Agent placement from cached workspace buffers", () => {
  const projectA = [
    { type: "agentConversation", sessionId: "session-a", agentId: "codex-acp" },
    { type: "editor" },
  ];
  const projectB = [
    { type: "agentConversation", sessionId: "session-b", agentId: "codex-acp" },
  ];

  test("returning to a cached workspace needs no remount or registration", () => {
    expect(editorAgentSessionIDs(projectA, "codex-acp")).toEqual(["session-a"]);
    expect(editorAgentSessionIDs(projectB, "codex-acp")).toEqual(["session-b"]);
    expect(editorAgentSessionIDs(projectA, "codex-acp")).toEqual(["session-a"]);
    expect(editorAgentSessionIDs([], "codex-acp")).toEqual([]);
  });

  test("another Agent's retained tabs do not take over the tool window", () => {
    expect(editorAgentSessionIDs(projectA, "claude-acp")).toEqual([]);
    expect(editorAgentSessionIDs([
      { type: "agentConversation", sessionId: "legacy" },
    ], "codex-acp")).toEqual(["legacy"]);
  });
});
