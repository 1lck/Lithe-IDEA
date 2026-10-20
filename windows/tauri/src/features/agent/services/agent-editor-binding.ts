/**
 * Resolve which session an Agent surface reads and whether an editor tab is
 * still owned by the connected Agent.
 *
 * The tool window follows the shared connection, while an editor tab carries
 * the session and Agent it was opened with. A tab from another Agent must not
 * hand its session to the current connection, and it must not fall back to the
 * globally selected conversation.
 */
export function resolveAgentEditorBinding({
  isEditor,
  boundSessionID,
  boundAgentID,
  activeAgentID,
  selectedSessionID,
}: {
  isEditor: boolean;
  boundSessionID: string | null;
  boundAgentID: string | null;
  activeAgentID: string;
  selectedSessionID: string | null;
}): { sessionID: string | null; isForeignAgent: boolean } {
  if (!isEditor) return { sessionID: selectedSessionID, isForeignAgent: false };
  const owner = boundAgentID === null || boundAgentID.length === 0 ? null : boundAgentID;
  return {
    sessionID: boundSessionID,
    isForeignAgent: owner !== null && owner !== activeAgentID,
  };
}

/** Derive placement from the current workspace buffers, never a mount registry. */
export function editorAgentSessionIDs(
  buffers: readonly { type: string; sessionId?: string; agentId?: string }[],
  agentID: string,
): string[] {
  return buffers.flatMap((buffer) =>
    buffer.type === "agentConversation" && typeof buffer.sessionId === "string" &&
    (!buffer.agentId || buffer.agentId === agentID) ? [buffer.sessionId] : [],
  );
}
