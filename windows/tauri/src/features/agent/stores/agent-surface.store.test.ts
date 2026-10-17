import { beforeEach, describe, expect, test } from "bun:test";
import { NEW_AGENT_DRAFT_KEY, useAgentSurfaceStore } from "./agent-surface.store";

beforeEach(() => {
  useAgentSurfaceStore.getState().actions.reset();
});

describe("agent surface placement", () => {
  test("registers an editor session once and releases it on close", () => {
    const { registerEditorSession, unregisterEditorSession } =
      useAgentSurfaceStore.getState().actions;

    registerEditorSession("session-a");
    registerEditorSession("session-a");
    registerEditorSession("session-b");
    expect(useAgentSurfaceStore.getState().editorSessionIDs).toEqual(["session-a", "session-b"]);

    unregisterEditorSession("session-a");
    expect(useAgentSurfaceStore.getState().editorSessionIDs).toEqual(["session-b"]);

    unregisterEditorSession("session-a");
    expect(useAgentSurfaceStore.getState().editorSessionIDs).toEqual(["session-b"]);
  });

  test("keeps unsent drafts separate per conversation across surfaces", () => {
    const { setDraft } = useAgentSurfaceStore.getState().actions;

    setDraft("session-a", {
      text: "keep this text",
      files: [{ uri: "file:///tmp/notes.txt", name: "notes.txt" }],
    });
    setDraft("session-b", { text: "other conversation", files: [] });

    expect(useAgentSurfaceStore.getState().drafts["session-a"]?.text).toBe("keep this text");
    expect(useAgentSurfaceStore.getState().drafts["session-a"]?.files).toHaveLength(1);
    expect(useAgentSurfaceStore.getState().drafts["session-b"]?.text).toBe("other conversation");
  });

  test("clears window-wide placement state when the workspace changes", () => {
    const { registerEditorSession, reset, setDetailsOpen, setDraft } =
      useAgentSurfaceStore.getState().actions;

    registerEditorSession("session-a");
    setDetailsOpen(true);
    setDraft("session-a", { text: "old project draft", files: [] });
    setDraft(NEW_AGENT_DRAFT_KEY, { text: "unsent new conversation", files: [] });

    reset();

    const state = useAgentSurfaceStore.getState();
    expect(state.editorSessionIDs).toEqual([]);
    expect(state.detailsOpen).toBe(false);
    expect(state.drafts).toEqual({});
  });

  test("clears a draft without disturbing the other conversation", () => {
    const { clearDraft, setDraft } = useAgentSurfaceStore.getState().actions;

    setDraft("session-a", { text: "first", files: [] });
    setDraft("session-b", { text: "second", files: [] });
    clearDraft("session-a");

    expect(useAgentSurfaceStore.getState().drafts["session-a"]).toBeUndefined();
    expect(useAgentSurfaceStore.getState().drafts["session-b"]?.text).toBe("second");
  });
});