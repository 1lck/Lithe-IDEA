import { useCallback, useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { AgentConversationContent } from "@/features/panes/types/pane-content.types";
import { openAgentToolWindow } from "../actions/agent-tool-window-actions";
import { AgentPanel } from "./agent-panel";

interface AgentConversationTabProps {
  buffer: AgentConversationContent;
  isActive: boolean;
}

/**
 * Editor placement of the Agent conversation.
 *
 * The tab owns the buffer identity only. Conversation state, drafts and the
 * ACP connection stay in the window-wide stores, so moving between the tab and
 * the tool window never starts a second session.
 */
export function AgentConversationTab({ buffer, isActive }: AgentConversationTabProps) {
  const updateBuffer = useBufferStore.use.actions().updateBuffer;
  const workspaceAtMount = useRef(useFileSystemStore.getState().rootFolderPath ?? null);
  const bufferID = buffer.id;

  // Closing the tab is a placement change, not a disconnect. Reveal the tool
  // window only when the tab was actually removed from this workspace; hidden
  // tabs and project switches must not pop the panel open.
  useEffect(() => {
    return () => {
      const stillOpen = useBufferStore
        .getState()
        .buffers.some((candidate) => candidate.id === bufferID);
      const workspaceNow = useFileSystemStore.getState().rootFolderPath ?? null;
      if (!stillOpen && workspaceNow === workspaceAtMount.current) openAgentToolWindow();
    };
  }, [bufferID]);

  const moveToToolWindow = useCallback(() => {
    useBufferStore.getState().actions.closeBufferForce(bufferID);
    openAgentToolWindow();
  }, [bufferID]);

  const rename = useCallback(
    (name: string) => {
      const current = useBufferStore
        .getState()
        .buffers.find((candidate) => candidate.id === bufferID);
      if (current === undefined || current.type !== "agentConversation" || current.name === name) {
        return;
      }
      updateBuffer({ ...current, name });
    },
    [bufferID, updateBuffer],
  );

  return (
    <AgentPanel
      isActive={isActive}
      placement="editor"
      sessionID={buffer.sessionId}
      agentId={buffer.agentId}
      onClose={moveToToolWindow}
      onMoveToToolWindow={moveToToolWindow}
      onTitleChange={rename}
    />
  );
}
