import {
  adjacentGitGutterChangeIndex,
  gitGutterChangeKey,
  type GitGutterChange,
} from "@/features/git/utils/git-gutter-changes";

/** The change an open inline review shows, bound to the text it was computed from. */
export interface GitGutterPeek {
  index: number;
  total: number;
  change: GitGutterChange;
  key: string;
  /** Monaco model version the change list was computed for. */
  version: number;
  /** Increments on every open, so a late action from a replaced review is ignored. */
  generation: number;
}

/**
 * Owns which change list is current and which change is open. It has no
 * Monaco dependency: the editor adapter reports content and model changes and
 * renders whatever `peek` is.
 */
export class GitGutterPeekSession {
  private changes: GitGutterChange[] = [];
  private version = -1;
  private generation = 0;
  private current: GitGutterPeek | null = null;

  get peek(): GitGutterPeek | null {
    return this.current;
  }

  get changeList(): readonly GitGutterChange[] {
    return this.changes;
  }

  /**
   * Publishes a change list computed for `version`. An open review stays open
   * only when the same change, with the same content, is still in the list.
   */
  setChanges(changes: GitGutterChange[], version: number): GitGutterPeek | null {
    this.changes = changes;
    this.version = version;
    const open = this.current;
    if (!open) return null;
    // A Git refresh (save, stage, external change) recomputes the list for
    // the same editor text; the review follows its change or closes when the
    // change is gone, for example after it was staged.
    const index = changes.findIndex((change) => gitGutterChangeKey(change) === open.key);
    this.current = index < 0 ? null : { ...open, index, total: changes.length, version };
    return this.current;
  }

  open(index: number, version: number): GitGutterPeek | null {
    if (version !== this.version) return null;
    const change = this.changes[index];
    if (!change) return null;
    this.current = {
      index,
      total: this.changes.length,
      change,
      key: gitGutterChangeKey(change),
      version,
      generation: ++this.generation,
    };
    return this.current;
  }

  navigate(direction: "previous" | "next", version: number): GitGutterPeek | null {
    const from = this.current?.index ?? -1;
    const index =
      from < 0
        ? direction === "next"
          ? 0
          : this.changes.length - 1
        : adjacentGitGutterChangeIndex(this.changes.length, from, direction);
    return index < 0 ? null : this.open(index, version);
  }

  /** Editing, switching models or disposing makes the open review stale. */
  close(): void {
    this.current = null;
  }

  /** Text edits invalidate the published list until it is recomputed. */
  invalidate(): void {
    this.current = null;
    this.changes = [];
    this.version = -1;
  }

  /** True only for the review that is open now, over the text it was computed from. */
  isCurrent(peek: GitGutterPeek, version: number): boolean {
    return (
      this.current !== null &&
      this.current.generation === peek.generation &&
      this.current.version === version &&
      this.version === version
    );
  }
}
