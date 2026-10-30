import type { StateStack } from "vscode-textmate";

export type TextmateLineResult = { tokens: any[]; ruleStack: StateStack };
export type TextmateLineTokenizer = (line: string, state: StateStack) => TextmateLineResult;
export type TextmateRow = { line: number; tokens: any[]; ruleStack: StateStack };
export type TextmateEdit = {
  rangeOffset: number;
  text: string;
  range: { startLineNumber: number; startColumn: number; endLineNumber: number; endColumn: number };
};

/**
 * One model's lines and the rule state after each, as the tokenizer worker sees
 * them. A file's tokens depend on its earlier lines only through that state, so
 * once a retokenized line ends in the state it ended in before, every later line
 * still stands. Stopping there keeps an edit's cost tied to what it changed
 * rather than to how much of the file follows it. Lines the main thread never
 * applied are not covered by that reasoning, see `invalidate`.
 */
export class TextmateDocument {
  private readonly states: (StateStack | undefined)[] = [];
  /** Next line to tokenize. */
  private cursor = 0;
  /** Lines before this one are tokenized even when their state already matches. */
  private dirtyEnd = 0;
  /** Where an interrupted pass continues once `cursor` has caught up. */
  private resume = 0;

  constructor(readonly lines: string[], public version: number, private readonly initial: StateStack) {}

  get complete(): boolean { return this.cursor >= this.lines.length; }

  /** Mirrors a Monaco edit event. Returns false for an event already seen. */
  applyEdit(changes: readonly TextmateEdit[], version: number): boolean {
    if (version <= this.version) return false;
    for (const change of [...changes].sort((a, b) => b.rangeOffset - a.rangeOffset)) {
      const start = change.range.startLineNumber - 1, end = change.range.endLineNumber - 1;
      const replacement = (this.lines[start].slice(0, change.range.startColumn - 1) + change.text + this.lines[end].slice(change.range.endColumn - 1)).split(/\r\n|\n/);
      const removed = end - start + 1;
      this.lines.splice(start, removed, ...replacement);
      if (start < this.states.length) {
        // The old end of the edit is what the new end has to match to converge.
        this.states.splice(start, removed, ...new Array(replacement.length - 1), this.states[end]);
      }
      const moved = (line: number) => line > end ? line + replacement.length - removed
        : line > start ? start + replacement.length : line;
      this.rewind(start);
      this.resume = moved(this.resume);
      this.dirtyEnd = Math.max(moved(this.dirtyEnd), start + replacement.length);
    }
    this.version = version;
    return true;
  }

  /**
   * Requires `[start, end)` to be tokenized again whatever its state says, for
   * lines the main thread asked for or could not apply. Rows posted for an older
   * version are dropped there while their states stay here, so without this a
   * later pass would converge on a state the editor never received, and the
   * lines after a typed comment opener would keep their old colors.
   */
  invalidate(start: number, end: number): void {
    this.rewind(Math.max(0, start));
    this.dirtyEnd = Math.max(this.dirtyEnd, Math.min(end, this.lines.length));
  }

  /** Moves the cursor back to `line`, remembering where its pass had reached. */
  private rewind(line: number): void {
    if (this.cursor <= line) return;
    if (this.dirtyEnd <= this.cursor) this.dirtyEnd = 0;
    if (this.resume <= this.cursor || this.resume >= this.lines.length) {
      this.resume = this.cursor;
    } else {
      // Only one earlier pass can be remembered, so this one walks through to
      // it, including the first line that pass had not validated.
      this.dirtyEnd = Math.max(this.dirtyEnd, this.resume + 1);
      this.resume = this.lines.length;
    }
    this.cursor = line;
  }

  /** Tokenizes up to `limit` lines, stopping early once `expired` returns true. */
  tokenize(tokenizeLine: TextmateLineTokenizer, limit: number, expired: () => boolean): TextmateRow[] {
    const rows: TextmateRow[] = [];
    while (!this.complete && rows.length < limit) {
      const index = this.cursor;
      const result = tokenizeLine(this.lines[index], index === 0 ? this.initial : this.states[index - 1]!);
      const previous = this.states[index];
      this.states[index] = result.ruleStack;
      rows.push({ line: index + 1, tokens: result.tokens, ruleStack: result.ruleStack });
      this.cursor = index + 1;
      if (this.cursor >= this.dirtyEnd && previous?.equals(result.ruleStack)) {
        this.cursor = Math.max(this.cursor, this.resume);
        this.resume = this.lines.length;
      }
      if (expired()) break;
    }
    return rows;
  }
}
