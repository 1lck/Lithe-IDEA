/**
 * `@` file references in the Agent prompt.
 *
 * The composer only uses this to decide which part of the draft opened the file
 * picker. The draft itself stays plain text and the chosen file travels as an
 * ACP file reference, so the match is kept pure and testable without a DOM or a
 * running adapter.
 */

/** Query of an unfinished `@` reference ending at the caret. */
export interface AgentMentionQuery {
  /** Index of the `@` that started the reference. */
  start: number;
  /** Text typed after `@`, empty right after the trigger. */
  query: string;
}

/**
 * Read an unfinished `@` reference from the text before the caret. A reference
 * starts at the beginning of the text or after whitespace and holds no
 * whitespace or second `@`, so a finished reference or an email address does
 * not reopen the picker while the user keeps typing.
 */
export function agentMentionQuery(textBeforeCaret: string): AgentMentionQuery | null {
  const match = /(?:^|\s)@([^\s@]*)$/.exec(textBeforeCaret);
  if (match === null) return null;
  const query = match[1] ?? "";
  return { start: textBeforeCaret.length - query.length - 1, query };
}

/**
 * Remove the `@query` token that opened the picker, so picking a file leaves no
 * stray text in the prompt. A draft edited after the picker opened keeps
 * whatever the user has typed since; only the matched range is dropped.
 */
export function removeAgentMention(text: string, mention: AgentMentionQuery): string {
  const end = Math.min(text.length, mention.start + 1 + mention.query.length);
  return `${text.slice(0, mention.start)}${text.slice(end)}`;
}
