import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBufferStore } from "./buffer.store";

const WORKSPACE = "buffer-agent-conversation-test";

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "Agent" }, "ready");
});

afterEach(() => {
  useBufferStore.getStore(WORKSPACE).setState({ buffers: [], activeBufferId: null });
});

describe("openAgentConversationBuffer", () => {
  test("focuses the existing editor tab for the same session", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    const first = store.getState().actions.openAgentConversationBuffer("session-a");
    const second = store.getState().actions.openAgentConversationBuffer("session-a");

    const tabs = store
      .getState()
      .buffers.filter((buffer) => buffer.type === "agentConversation");
    expect(second).toBe(first);
    expect(tabs).toHaveLength(1);
    expect(store.getState().activeBufferId).toBe(first);
  });

  test("gives each session its own deterministic virtual path", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.getState().actions.openAgentConversationBuffer("session-a");
    store.getState().actions.openAgentConversationBuffer("session-b");

    const tabs = store
      .getState()
      .buffers.filter((buffer) => buffer.type === "agentConversation");
    expect(tabs).toHaveLength(2);
    expect(tabs.map((buffer) => buffer.path).sort()).toEqual([
      "agent-conversation://session-a",
      "agent-conversation://session-b",
    ]);
  });

  test("keeps the Agent that owns the session on the tab", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    store.getState().actions.openAgentConversationBuffer("session-a", "claude-acp");

    const tab = store
      .getState()
      .buffers.find((buffer) => buffer.type === "agentConversation");
    expect(tab?.type).toBe("agentConversation");
    if (tab?.type !== "agentConversation") throw new Error("Agent tab missing");
    expect(tab.agentId).toBe("claude-acp");
  });

  test("keeps the Agent conversation out of automatic tab eviction", () => {
    const store = useBufferStore.getStore(WORKSPACE);
    const id = store.getState().actions.openAgentConversationBuffer("session-a");

    store.setState({ maxOpenTabs: 1 });
    store.getState().actions.openAgentConversationBuffer("session-b");

    expect(
      store.getState().buffers.some((buffer) => buffer.id === id && buffer.type === "agentConversation"),
    ).toBe(true);
  });
});
