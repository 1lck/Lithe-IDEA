/**
 * How the transcript is laid out, without changing the stored conversation.
 *
 * This is the Windows counterpart of `AgentTranscriptItem` and
 * `AgentMarkdownMessage.segments` on macOS: adjacent tool calls form one group,
 * a finished turn's statistics follow its last message, search filters the
 * grouped items, and a reply is split into prose and fenced code blocks. It is
 * pure so the panel and the tests share one definition.
 */

import type { AgentConversationMessage } from "../types/agent.types";
import type { AgentTurnStatistics } from "../types/agent-turn-statistics";

export type AgentTranscriptItem =
  | { kind: "message"; id: string; message: AgentConversationMessage }
  | { kind: "toolGroup"; id: string; tools: AgentConversationMessage[] }
  | { kind: "turnSummary"; id: string; turn: AgentTurnStatistics };

function contains(text: string | null | undefined, query: string): boolean {
  return text != null && text.toLocaleLowerCase().includes(query.toLocaleLowerCase());
}

/** A tool matches on its title, evidence, or any location path. */
export function toolMatches(message: AgentConversationMessage, query: string): boolean {
  const details = message.toolDetails;
  return (
    contains(message.text, query) ||
    contains(details.input, query) ||
    contains(details.output, query) ||
    details.content.some((entry) => contains(entry.title, query) || contains(entry.text, query)) ||
    details.locations.some((location) => contains(location.path, query))
  );
}

export function itemMatches(item: AgentTranscriptItem, query: string): boolean {
  if (query.length === 0) return true;
  switch (item.kind) {
    case "message":
      return contains(item.message.text, query);
    case "toolGroup":
      return item.tools.some((tool) => toolMatches(tool, query));
    case "turnSummary":
      return false;
  }
}

/** Prose and user messages end a group, preserving the conversation order. */
export function groupTranscript(
  messages: AgentConversationMessage[],
  turns: AgentTurnStatistics[] = [],
): AgentTranscriptItem[] {
  const summaries = new Map<string, AgentTurnStatistics>();
  for (const turn of turns) {
    if (turn.endingMessageID !== null) summaries.set(turn.endingMessageID, turn);
  }
  const items: AgentTranscriptItem[] = [];
  let tools: AgentConversationMessage[] = [];
  const flushTools = () => {
    if (tools.length === 0) return;
    items.push({ kind: "toolGroup", id: `tools:${tools[0].id}`, tools });
    tools = [];
  };
  for (const message of messages) {
    if (message.role === "tool") {
      tools.push(message);
    } else {
      flushTools();
      items.push({ kind: "message", id: message.id, message });
    }
    const summary = summaries.get(message.id);
    if (summary !== undefined) {
      flushTools();
      items.push({ kind: "turnSummary", id: `turn:${summary.id}`, turn: summary });
    }
  }
  flushTools();
  return items;
}

/** Counts for the activity bar below the transcript. */
export function activitySummary(messages: AgentConversationMessage[]) {
  const tools = messages.filter((message) => message.role === "tool");
  return {
    tasks: tools.length,
    running: tools.filter(
      (tool) => tool.toolStatus === "in_progress" || tool.toolStatus === "pending",
    ).length,
    failed: tools.filter((tool) => tool.toolStatus === "failed").length,
    edits: tools.filter(
      (tool) => tool.toolDetails.kind === "edit" || tool.toolDetails.kind === "delete",
    ).length,
  };
}

export type AgentMessageSegment =
  | { kind: "prose"; text: string }
  | { kind: "code"; language: string; code: string };

function trimNewlines(text: string): string {
  return text.replace(/^\n+|\n+$/g, "");
}

/** Fences that have not been closed yet (still streaming) are treated as code. */
export function messageSegments(text: string): AgentMessageSegment[] {
  const segments: AgentMessageSegment[] = [];
  let prose = "";
  let code = "";
  let language = "";
  let inCode = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("```")) {
      if (inCode) {
        segments.push({ kind: "code", language, code: trimNewlines(code) });
        code = "";
        inCode = false;
      } else {
        if (prose.trim().length > 0) segments.push({ kind: "prose", text: trimNewlines(prose) });
        prose = "";
        language = line.slice(3).trim();
        inCode = true;
      }
      continue;
    }
    if (inCode) code += `${line}\n`;
    else prose += `${line}\n`;
  }
  if (inCode) segments.push({ kind: "code", language, code: trimNewlines(code) });
  else if (prose.trim().length > 0) segments.push({ kind: "prose", text: trimNewlines(prose) });
  return segments;
}

/** Inline Markdown spans, matching `.inlineOnlyPreservingWhitespace` on macOS. */
export type AgentInlineSpan =
  | { kind: "text"; text: string }
  | { kind: "strong"; text: string }
  | { kind: "emphasis"; text: string }
  | { kind: "code"; text: string }
  | { kind: "link"; text: string; href: string };

const INLINE_PATTERN =
  /(`+)([\s\S]*?[^`])\1(?!`)|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*|_([^_\n]+)_|\[([^\]\n]+)\]\(([^)\s]+)\)/g;

/**
 * Parse inline Markdown only: code spans, strong, emphasis and links. Block
 * syntax stays as typed text, and whitespace is preserved for `pre-wrap`.
 */
export function inlineSpans(text: string): AgentInlineSpan[] {
  const spans: AgentInlineSpan[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE_PATTERN)) {
    const index = match.index ?? 0;
    if (index > last) spans.push({ kind: "text", text: text.slice(last, index) });
    if (match[2] !== undefined) spans.push({ kind: "code", text: match[2] });
    else if (match[3] !== undefined || match[4] !== undefined) {
      spans.push({ kind: "strong", text: match[3] ?? match[4] ?? "" });
    } else if (match[5] !== undefined || match[6] !== undefined) {
      spans.push({ kind: "emphasis", text: match[5] ?? match[6] ?? "" });
    } else if (match[7] !== undefined && match[8] !== undefined) {
      spans.push({ kind: "link", text: match[7], href: match[8] });
    }
    last = index + match[0].length;
  }
  if (last < text.length) spans.push({ kind: "text", text: text.slice(last) });
  return spans;
}

/** First line of a prompt, at most 40 characters, for a provisional tab title. */
export function provisionalTabTitle(prompt: string): string {
  const line = prompt.split(/\r?\n/)[0] ?? prompt;
  return line.length > 40 ? `${line.slice(0, 40)}…` : line;
}
