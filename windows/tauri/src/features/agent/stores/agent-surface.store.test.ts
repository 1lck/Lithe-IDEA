import { beforeEach, describe, expect, test } from "bun:test";
import { agentDraftKey, NEW_AGENT_DRAFT_KEY, useAgentSurfaceStore } from "./agent-surface.store";

beforeEach(() => {
  useAgentSurfaceStore.getState().actions.reset();
});

describe("agent surface placement", () => {
  test("a shared session id never shares drafts between Agents", () => {
    const { setDraftText } = useAgentSurfaceStore.getState().actions;
    setDraftText(agentDraftKey("codex-acp", "same-id"), "Codex draft");
    setDraftText(agentDraftKey("claude-acp", "same-id"), "Claude draft");
    expect(useAgentSurfaceStore.getState().drafts[agentDraftKey("codex-acp", "same-id")]?.text).toBe("Codex draft");
    expect(useAgentSurfaceStore.getState().drafts[agentDraftKey("claude-acp", "same-id")]?.text).toBe("Claude draft");
  });

  test("session creation migrates the draft and preserves an occupied destination", () => {
    const { setDraft, setDraftText, moveDraft } = useAgentSurfaceStore.getState().actions;
    const source = agentDraftKey("codex-acp", null);
    const target = agentDraftKey("codex-acp", "created");
    const draft = { text: "unsent text", files: [{ uri: "file:///C:/notes.txt", name: "notes.txt" }] };
    setDraft(source, draft);
    moveDraft(source, target);
    expect(useAgentSurfaceStore.getState().drafts[source]).toBeUndefined();
    expect(useAgentSurfaceStore.getState().drafts[target]).toEqual(draft);
    setDraftText(source, "another draft");
    moveDraft(source, target);
    expect(useAgentSurfaceStore.getState().drafts[target]).toEqual(draft);
    expect(useAgentSurfaceStore.getState().drafts[source]?.text).toBe("another draft");
  });

  test("attachment overflow fails atomically without changing draft text or files", () => {
    const { setDraftText, appendDraftFiles } = useAgentSurfaceStore.getState().actions;
    const key = agentDraftKey("codex-acp", null);
    setDraftText(key, "keep this");
    appendDraftFiles(key, Array.from({ length: 32 }, (_, index) => `file:///C:/file-${index}.txt`));
    const before = useAgentSurfaceStore.getState().drafts[key];
    expect(() => appendDraftFiles(key, ["file:///C:/overflow.txt"])).toThrow();
    expect(useAgentSurfaceStore.getState().drafts[key]).toBe(before);
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
    const { reset, setDetailsOpen, setDraft, setReasoningExpanded } =
      useAgentSurfaceStore.getState().actions;

    setDetailsOpen(true);
    setDraft("session-a", { text: "old project draft", files: [] });
    setDraft(NEW_AGENT_DRAFT_KEY, { text: "unsent new conversation", files: [] });
    setReasoningExpanded("session-a:reasoning-1", true);

    reset();

    const state = useAgentSurfaceStore.getState();
    expect(state.detailsOpen).toBe(false);
    expect(state.drafts).toEqual({});
    expect(state.reasoningExpanded).toEqual({});
  });

  test("reasoning expansion survives a filtered transcript remount", () => {
    const { setReasoningExpanded } = useAgentSurfaceStore.getState().actions;

    setReasoningExpanded("session-a:reasoning-1", true);
    setReasoningExpanded("session-b:reasoning-1", false);

    // Filtering unmounts the row; the preference remains owned by the surface
    // store instead of dying with that component instance.
    expect(useAgentSurfaceStore.getState().reasoningExpanded).toEqual({
      "session-a:reasoning-1": true,
      "session-b:reasoning-1": false,
    });
  });

  test("clears a draft without disturbing the other conversation", () => {
    const { clearDraft, setDraft } = useAgentSurfaceStore.getState().actions;

    setDraft("session-a", { text: "first", files: [] });
    setDraft("session-b", { text: "second", files: [] });
    clearDraft("session-a");

    expect(useAgentSurfaceStore.getState().drafts["session-a"]).toBeUndefined();
    expect(useAgentSurfaceStore.getState().drafts["session-b"]?.text).toBe("second");
  });

  test("text and attachment updates merge without restoring stale fields", () => {
    const { setDraftFiles, setDraftText } = useAgentSurfaceStore.getState().actions;
    const file = { uri: "file:///tmp/notes.txt", name: "notes.txt" };

    setDraftText("session-a", "hello");
    setDraftFiles("session-a", [file]);
    setDraftText("session-a", "hello world");

    expect(useAgentSurfaceStore.getState().drafts["session-a"]).toEqual({
      text: "hello world",
      files: [file],
    });

    // Success clears text and attachments through two separate callbacks; each
    // must keep the other field's latest value.
    setDraftText("session-a", "");
    setDraftFiles("session-a", []);
    expect(useAgentSurfaceStore.getState().drafts["session-a"]).toEqual({ text: "", files: [] });
  });
});
