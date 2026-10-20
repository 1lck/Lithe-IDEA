import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";

/**
 * Show the conversation in the main editor group. The buffer path is derived
 * from the session, so asking twice focuses the existing tab instead of
 * creating another connection or a second copy of the same conversation.
 */
export function openAgentConversationInEditor(sessionID: string, agentId: string): string {
  activateMainEditorPane();
  return useBufferStore.getState().actions.openAgentConversationBuffer(sessionID, agentId);
}
