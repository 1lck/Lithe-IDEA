import type { GitDiff, GitDiffSplitRow } from "../types/git.types";

export type GitDiffViewMode = "unified" | "split";

export interface SplitDiffLayoutItem {
  rowIndex: number;
  top: number;
  height: number;
}

export interface SplitDiffTransition {
  id: string;
  kind: GitDiffSplitRow["kind"];
  leftStart: number;
  leftEnd: number;
  rightStart: number;
  rightEnd: number;
}

export interface SplitDiffLayout {
  leftItems: SplitDiffLayoutItem[];
  rightItems: SplitDiffLayoutItem[];
  transitions: SplitDiffTransition[];
  leftHeight: number;
  rightHeight: number;
  contentHeight: number;
}

interface TransitionSignature {
  kind: GitDiffSplitRow["kind"];
  hasLeft: boolean;
  hasRight: boolean;
}

interface ActiveTransition {
  id: string;
  signature: TransitionSignature;
  leftStart: number;
  rightStart: number;
}

function signaturesMatch(left: TransitionSignature, right: TransitionSignature): boolean {
  return (
    left.kind === right.kind &&
    left.hasLeft === right.hasLeft &&
    left.hasRight === right.hasRight
  );
}

export function resolveDiffViewMode(
  diff: Pick<GitDiff, "is_new" | "is_deleted">,
  preferredMode: GitDiffViewMode,
): GitDiffViewMode {
  return diff.is_new || diff.is_deleted ? "unified" : preferredMode;
}

export function planSplitDiffLayout(rows: GitDiffSplitRow[]): SplitDiffLayout {
  const leftItems: SplitDiffLayoutItem[] = [];
  const rightItems: SplitDiffLayoutItem[] = [];
  const transitions: SplitDiffTransition[] = [];
  let leftHeight = 0;
  let rightHeight = 0;
  let activeTransition: ActiveTransition | null = null;

  const finishTransition = () => {
    if (!activeTransition) return;

    transitions.push({
      id: activeTransition.id,
      kind: activeTransition.signature.kind,
      leftStart: activeTransition.leftStart,
      leftEnd: leftHeight,
      rightStart: activeTransition.rightStart,
      rightEnd: rightHeight,
    });
    activeTransition = null;
  };

  rows.forEach((row, rowIndex) => {
    const hasLeft = row.old_content !== undefined;
    const hasRight = row.new_content !== undefined;
    const signature: TransitionSignature = { kind: row.kind, hasLeft, hasRight };
    const isDifference = row.kind !== "context" && (hasLeft || hasRight);

    if (isDifference) {
      if (!activeTransition || !signaturesMatch(activeTransition.signature, signature)) {
        finishTransition();
        activeTransition = {
          id: `transition-${rowIndex}`,
          signature,
          leftStart: leftHeight,
          rightStart: rightHeight,
        };
      }
    } else {
      finishTransition();
    }

    if (hasLeft) {
      leftItems.push({ rowIndex, top: leftHeight, height: 1 });
      leftHeight += 1;
    }

    if (hasRight) {
      rightItems.push({ rowIndex, top: rightHeight, height: 1 });
      rightHeight += 1;
    }
  });

  finishTransition();

  return {
    leftItems,
    rightItems,
    transitions,
    leftHeight,
    rightHeight,
    contentHeight: Math.max(leftHeight, rightHeight),
  };
}
