/**
 * Slash-command completion shared by the Agent composer and its tests.
 *
 * Mirrors `AgentCommand` and `AgentCommandCompletion` on macOS: an Agent
 * advertises commands for the session over ACP, selecting one only inserts
 * `/name ` into the draft, and the Agent interprets the sent text. A `$name`
 * skill is inserted without the slash. Chinese input methods type `、` on the
 * `/` key and `¥`/`￥` on `$`, so those characters open the same lists.
 */

import type { AgentCommand } from "../types/agent.types";

export type AgentCommandKey = "submit" | "escape" | "up" | "down" | "tab";

export interface AgentCommandKeyState {
  highlightedIndex: number;
  /** Escape dismisses the list until the draft changes again. */
  dismissed: boolean;
}

export type AgentCommandKeyOutcome =
  | { kind: "ignored" }
  | { kind: "handled"; state: AgentCommandKeyState }
  | { kind: "complete"; command: AgentCommand; highlightedIndex: number }
  | { kind: "send" }
  | { kind: "cancel" };

/** `¥`/`￥` on the `$` key and `、` on the `/` key open the same lists. */
export function commandTrigger(character: string): "/" | "$" | null {
  switch (character) {
    case "/":
    case "、":
      return "/";
    case "$":
    case "¥":
    case "￥":
      return "$";
    default:
      return null;
  }
}

/** Codex lists skills as `$name`; they are mentioned as `$name`, not `/$name`. */
export function isSkillCommand(command: AgentCommand): boolean {
  return command.name.startsWith("$");
}

/** Text the composer inserts to invoke the command. */
export function commandInvocation(command: AgentCommand): string {
  return isSkillCommand(command) ? command.name : `/${command.name}`;
}

/**
 * Commands matching the token being typed, or null when the draft is not a
 * command prefix. `/` lists every command; `$` lists only skills, and only when
 * the Agent advertised some, so a literal `$` is not intercepted. Prefix
 * matches come before substring matches, as on macOS.
 */
export function commandSuggestions(
  draft: string,
  commands: AgentCommand[],
): AgentCommand[] | null {
  const trigger = commandTrigger(draft.slice(0, 1));
  if (trigger === null) return null;
  const candidates = trigger === "$" ? commands.filter(isSkillCommand) : commands;
  if (candidates.length === 0) return null;
  const query = draft.slice(1).toLowerCase();
  if (/\s/.test(query)) return null;
  const key = (command: AgentCommand) =>
    (isSkillCommand(command) ? command.name.slice(1) : command.name).toLowerCase();
  const prefixed = candidates.filter((command) => key(command).startsWith(query));
  const contained = candidates.filter(
    (command) => !key(command).startsWith(query) && key(command).includes(query),
  );
  return [...prefixed, ...contained];
}

/** Wraps in both directions so Up from the first row lands on the last. */
export function moveCommandHighlight(
  current: number,
  offset: number,
  count: number,
): number {
  if (count <= 0) return 0;
  return ((Math.min(current, count - 1) + offset + count) % count + count) % count;
}

/** The draft after completing a command, including the separating space. */
export function completedCommandDraft(command: AgentCommand): string {
  return `${commandInvocation(command)} `;
}

/**
 * Shared key handling for Return, Esc, arrow keys and Tab. Completing a
 * command edits the draft; only a send result starts a prompt.
 */
export function resolveCommandKey(
  state: AgentCommandKeyState,
  key: AgentCommandKey,
  draft: string,
  commands: AgentCommand[],
  isResponding: boolean,
): AgentCommandKeyOutcome {
  const suggestions = state.dismissed ? null : commandSuggestions(draft, commands);
  switch (key) {
    case "escape":
      if (suggestions !== null) {
        return { kind: "handled", state: { ...state, dismissed: true } };
      }
      return isResponding ? { kind: "cancel" } : { kind: "ignored" };
    case "submit":
      // A fully typed command sends; completing one only edits the draft.
      if (
        suggestions === null ||
        suggestions.length === 0 ||
        suggestions.some((command) => commandInvocation(command) === draft)
      ) {
        return { kind: "send" };
      }
      return completeHighlighted(suggestions, state.highlightedIndex);
    case "up":
    case "down":
      if (suggestions === null || suggestions.length === 0) return { kind: "ignored" };
      return {
        kind: "handled",
        state: {
          ...state,
          highlightedIndex: moveCommandHighlight(
            state.highlightedIndex,
            key === "up" ? -1 : 1,
            suggestions.length,
          ),
        },
      };
    case "tab":
      if (suggestions === null || suggestions.length === 0) return { kind: "ignored" };
      return completeHighlighted(suggestions, state.highlightedIndex);
  }
}

function completeHighlighted(
  suggestions: AgentCommand[],
  highlightedIndex: number,
): AgentCommandKeyOutcome {
  const index = Math.min(highlightedIndex, suggestions.length - 1);
  const command = suggestions[index];
  if (command === undefined) return { kind: "send" };
  return { kind: "complete", command, highlightedIndex: index };
}