export const AGENT_CONVERSATION_PATH_PREFIX = "agent-conversation://";

export function agentConversationPath(sessionID: string): string {
  return `${AGENT_CONVERSATION_PATH_PREFIX}${encodeURIComponent(sessionID)}`;
}

export function isAgentConversationPath(path: string | undefined): boolean {
  return path?.startsWith(AGENT_CONVERSATION_PATH_PREFIX) === true;
}

export function agentConversationSessionID(path: string): string | null {
  if (!isAgentConversationPath(path)) return null;
  const encoded = path.slice(AGENT_CONVERSATION_PATH_PREFIX.length);
  if (encoded.length === 0) return null;
  try {
    return decodeURIComponent(encoded);
  } catch {
    return encoded;
  }
}