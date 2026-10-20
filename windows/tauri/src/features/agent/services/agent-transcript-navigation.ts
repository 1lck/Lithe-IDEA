/**
 * Presentation-only index of the transcript's user turns, the Windows
 * counterpart of `AgentTranscriptNavigationContent` on macOS.
 *
 * Tools and reasoning belong to the preceding prompt, but only actual Agent
 * prose is used for the reply preview. The rail never mutates the conversation.
 */

import type { AgentConversationMessage } from "../types/agent.types";

export interface AgentTranscriptNavigationEntry {
  /** Id of the user message that started the turn. */
  id: string;
  /** First 320 characters of the prompt. */
  prompt: string;
  /** First 640 characters of the turn's latest Agent prose, trimmed. */
  reply: string;
}

export interface AgentTranscriptNavigation {
  entries: AgentTranscriptNavigationEntry[];
  /** Every message that belongs to a turn, keyed to that turn's user message. */
  turnByMessageID: Record<string, string>;
}

const PROMPT_LIMIT = 320;
const REPLY_LIMIT = 640;

export function transcriptNavigation(
  messages: AgentConversationMessage[],
): AgentTranscriptNavigation {
  const entries: AgentTranscriptNavigationEntry[] = [];
  const turnByMessageID: Record<string, string> = {};
  for (const message of messages) {
    if (message.role === "user") {
      entries.push({ id: message.id, prompt: message.text.slice(0, PROMPT_LIMIT), reply: "" });
    }
    const current = entries[entries.length - 1];
    if (current === undefined) continue;
    turnByMessageID[message.id] = current.id;
    if (message.role === "agent") {
      const excerpt = message.text.slice(0, REPLY_LIMIT).trim();
      if (excerpt.length > 0) current.reply = excerpt;
    }
  }
  return { entries, turnByMessageID };
}