/**
 * Markdown rendering for exported conversations.
 *
 * A direct port of `AgentHistoryDocument.markdown` on macOS: one section per
 * conversation, one block per message, tool messages keeping their status,
 * input, output and content. Labels are passed in so the module stays pure and
 * testable; the `Agent` role is a protocol name and is not localised.
 */

import type { AgentConversationMessage } from "../types/agent.types";

export interface AgentHistoryDocument {
  id: string;
  title: string | null;
  messages: AgentConversationMessage[];
}

export interface AgentHistoryExportLabels {
  untitled: string;
  you: string;
  tool: string;
}

function roleHeading(role: AgentConversationMessage["role"], labels: AgentHistoryExportLabels) {
  if (role === "user") return labels.you;
  if (role === "tool") return labels.tool;
  return "Agent";
}

export function historyMarkdown(
  documents: AgentHistoryDocument[],
  labels: AgentHistoryExportLabels,
): string {
  const rendered = documents.map((document) => {
    const title = (document.title ?? labels.untitled).replace(/\r?\n/g, " ");
    const sections = [`# ${title}`, `Session ID: ${document.id}`];
    for (const message of document.messages) {
      let content = `## ${roleHeading(message.role, labels)}\n\n${message.text}`;
      if (message.toolStatus !== null) content += `\n\nStatus: ${message.toolStatus}`;
      for (const detail of [message.toolDetails.input, message.toolDetails.output]) {
        if (detail !== null) content += `\n\n${detail}`;
      }
      for (const block of message.toolDetails.content) content += `\n\n${block.text}`;
      sections.push(content);
    }
    return sections.join("\n\n");
  });
  return `${rendered.join("\n\n---\n\n")}\n`;
}
