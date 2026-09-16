/** Persistent source text in Monaco's normalized UTF-16 coordinate space.
 * Untouched pieces retain their exact newlines. Undo versions share pieces,
 * avoiding a full document snapshot for every keystroke.
 */
type Piece = Readonly<{
  text?: string;
  left?: Piece;
  right?: Piece;
  height: number;
  first: string;
  last: string;
  sourceLength: number;
  length: number;
}>;
const height = (piece: Piece | undefined) => piece?.height ?? 0;
const length = (piece: Piece | undefined) => piece?.length ?? 0;
const sourceLength = (piece: Piece | undefined) => piece?.sourceLength ?? 0;

function leaf(text: string): Piece | undefined {
  if (!text) return undefined;
  return { text, first: text[0], last: text[text.length - 1], height: 1, sourceLength: text.length, length: text.length - (text.match(/\r\n/g)?.length ?? 0) };
}
function branch(left: Piece | undefined, right: Piece | undefined): Piece | undefined {
  if (!left) return right;
  if (!right) return left;
  return { left, right, first: left.first, last: right.last, height: Math.max(left.height, right.height) + 1,
    sourceLength: left.sourceLength + right.sourceLength, length: left.length + right.length };
}
function balance(left: Piece | undefined, right: Piece | undefined): Piece | undefined {
  if (height(left) > height(right) + 1) {
    const l = left!;
    if (height(l.left) >= height(l.right)) return branch(l.left, branch(l.right, right));
    return branch(branch(l.left, l.right!.left), branch(l.right!.right, right));
  }
  if (height(right) > height(left) + 1) {
    const r = right!;
    if (height(r.right) >= height(r.left)) return branch(branch(left, r.left), r.right);
    return branch(branch(left, r.left!.left), branch(r.left!.right, r.right));
  }
  return branch(left, right);
}
function replaceLastCR(piece: Piece): Piece {
  if (piece.text !== undefined) return leaf(piece.text.slice(0, -1) + "\n")!;
  return branch(piece.left, replaceLastCR(piece.right!))!;
}
function join(left: Piece | undefined, right: Piece | undefined): Piece | undefined {
  // Deleting between a bare CR and an LF must not collapse two logical lines
  // into a single CRLF. Canonicalize only that newly joined boundary to LF/LF.
  if (left?.last === "\r" && right?.first === "\n") left = replaceLastCR(left);
  if (height(left) > height(right) + 1) return balance(left!.left, join(left!.right, right));
  if (height(right) > height(left) + 1) return balance(join(left, right!.left), right!.right);
  return branch(left, right);
}
function fromText(text: string): Piece | undefined {
  let result: Piece | undefined;
  for (let start = 0; start < text.length;) {
    let end = Math.min(start + 1024, text.length);
    if (text[end - 1] === "\r" && text[end] === "\n") end++;
    result = join(result, leaf(text.slice(start, end)));
    start = end;
  }
  return result;
}
function rawOffset(text: string, offset: number): number {
  let raw = 0;
  for (let normalized = 0; normalized < offset; normalized++) {
    raw += text[raw] === "\r" && text[raw + 1] === "\n" ? 2 : 1;
  }
  return raw;
}
function sourceOffset(piece: Piece | undefined, offset: number): number {
  if (!piece) return 0;
  if (piece.text !== undefined) return rawOffset(piece.text, offset);
  const leftLength = length(piece.left);
  return offset <= leftLength ? sourceOffset(piece.left, offset)
    : sourceLength(piece.left) + sourceOffset(piece.right, offset - leftLength);
}
function split(piece: Piece | undefined, offset: number): [Piece | undefined, Piece | undefined] {
  if (!piece || offset <= 0) return [undefined, piece];
  if (offset >= piece.length) return [piece, undefined];
  if (piece.text !== undefined) {
    const raw = rawOffset(piece.text, offset);
    return [leaf(piece.text.slice(0, raw)), leaf(piece.text.slice(raw))];
  }
  if (offset < length(piece.left)) {
    const [before, after] = split(piece.left, offset);
    return [before, join(after, piece.right)];
  }
  const [before, after] = split(piece.right, offset - length(piece.left));
  return [join(piece.left, before), after];
}
function textOf(piece: Piece | undefined): string {
  const parts: string[] = [];
  function visit(node: Piece | undefined) {
    if (!node) return;
    if (node.text !== undefined) parts.push(node.text);
    else { visit(node.left); visit(node.right); }
  }
  visit(piece);
  return parts.join("");
}
function slice(piece: Piece | undefined, offset: number, count: number): string {
  return textOf(split(split(piece, offset)[1], count)[0]);
}

export interface NormalizedTextChange { rangeOffset: number; rangeLength: number; text: string }
export interface SourceTextChange { offset: number; length: number; text: string }

export class SourceText {
  private current: Piece | undefined;
  private readonly versions = new Map<number, Piece | undefined>();
  private readonly defaultEOL: string;
  private currentVersion: number;
  private newestVersion: number;

  constructor(text: string, version: number) {
    this.current = fromText(text);
    this.versions.set(version, this.current);
    this.currentVersion = this.newestVersion = version;
    this.defaultEOL = text.match(/\r\n|\r|\n/)?.[0] ?? "\n";
  }
  get value(): string { return textOf(this.current); }

  private remember(version: number): void {
    // Monaco 0.55.1 assigns new edits its monotonically increasing versionId,
    // but restores alternativeVersionId on undo/redo (including grouped edits).
    // A new edit after undo discards the redo branch. Only those unreachable
    // roots may be pruned; a fixed-size cache would corrupt older mixed-EOL undo.
    if (!this.versions.has(version)) {
      if (this.currentVersion < this.newestVersion) {
        for (const saved of this.versions.keys()) {
          if (saved > this.currentVersion) this.versions.delete(saved);
        }
      }
      this.newestVersion = version;
    }
    this.currentVersion = version;
    this.versions.set(version, this.current);
  }

  /** Translate a simultaneous Monaco batch to original-source UTF-16 edits. */
  apply(changes: readonly NormalizedTextChange[], version: number): SourceTextChange[] {
    const previous = this.current;
    const restoring = this.versions.has(version);
    const target = this.versions.get(version);
    let delta = 0;
    const translated = [...changes].sort((a, b) => a.rangeOffset - b.rangeOffset).map(change => {
      const normalized = change.text.replace(/\r\n|\r/g, "\n");
      const text = restoring ? slice(target, change.rangeOffset + delta, normalized.length)
        : normalized.replace(/\n/g, this.defaultEOL);
      delta += normalized.length - change.rangeLength;
      const start = sourceOffset(previous, change.rangeOffset);
      return { change, text, offset: start,
        length: sourceOffset(previous, change.rangeOffset + change.rangeLength) - start };
    });
    for (const { change, text } of [...translated].reverse()) {
      const [before, rest] = split(this.current, change.rangeOffset);
      this.current = join(join(before, fromText(text)), split(rest, change.rangeLength)[1]);
    }
    if (restoring) this.current = target;
    this.remember(version);
    // Include adjacent code units so a newly joined CR/LF boundary correction
    // reaches the native mirror in the same atomic batch. Merge overlaps.
    const ranges: { start: number; end: number }[] = [];
    for (const { change } of translated) {
      const next = { start: Math.max(0, change.rangeOffset - 1),
        end: Math.min(length(previous), change.rangeOffset + change.rangeLength + 1) };
      // JSON/Swift strings cannot carry half of a UTF-16 surrogate pair.
      const firstUnit = slice(previous, next.start, 1).charCodeAt(0);
      const lastUnit = slice(previous, Math.max(0, next.end - 1), 1).charCodeAt(0);
      if (firstUnit >= 0xdc00 && firstUnit <= 0xdfff) next.start--;
      if (lastUnit >= 0xd800 && lastUnit <= 0xdbff) next.end++;
      const last = ranges[ranges.length - 1];
      if (last && next.start <= last.end) last.end = Math.max(last.end, next.end);
      else ranges.push(next);
    }
    return ranges.map(range => {
      let before = 0, inside = 0;
      for (const { change } of translated) {
        const delta = change.text.replace(/\r\n|\r/g, "\n").length - change.rangeLength;
        if (change.rangeOffset < range.start) before += delta;
        else if (change.rangeOffset <= range.end) inside += delta;
      }
      const offset = sourceOffset(previous, range.start);
      return { offset, length: sourceOffset(previous, range.end) - offset,
        text: slice(this.current, range.start + before, range.end - range.start + inside) };
    });
  }

  /** External replacement supplies exact bytes and stays in Monaco's undo history. */
  replace(text: string, version: number): void {
    this.current = fromText(text);
    this.remember(version);
  }
}
