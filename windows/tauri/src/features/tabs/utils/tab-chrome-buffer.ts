import { getDiffTabFileName } from "@/features/git/utils/diff-buffer-label";
import type { PaneContent } from "@/features/panes/types/pane-content.types";

const EMPTY_TOKENS: never[] = [];

export function toTabChromeBuffer(buffer: PaneContent): PaneContent {
  if (buffer.type === "editor") {
    return {
      ...buffer,
      content: "",
      savedContent: "",
      tokens: EMPTY_TOKENS,
    };
  }

  if (buffer.type === "diff") {
    return {
      ...buffer,
      content: "",
      savedContent: "",
    };
  }

  return buffer;
}

function tabChromeBufferEqual(left: PaneContent, right: PaneContent): boolean {
  if (left.id !== right.id || left.type !== right.type) return false;
  if (
    left.path !== right.path ||
    left.name !== right.name ||
    left.isPinned !== right.isPinned ||
    left.isPreview !== right.isPreview ||
    left.isActive !== right.isActive
  ) {
    return false;
  }

  if (left.type === "editor" && right.type === "editor") {
    return left.isDirty === right.isDirty && left.isVirtual === right.isVirtual;
  }

  // Reused diff tabs derive their title from the selected comparison, not only
  // from the buffer path: the Commit preview and the Git Log commit-file
  // preview both keep one tab while the arrows switch files.
  if (left.type === "diff" && right.type === "diff") {
    return getDiffTabFileName(left.diffData) === getDiffTabFileName(right.diffData);
  }

  return true;
}

export function tabChromeBuffersEqual(
  left: readonly PaneContent[] | null | undefined,
  right: readonly PaneContent[] | null | undefined,
): boolean {
  if (left === right) return true;
  if (!left || !right || left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (!tabChromeBufferEqual(left[index], right[index])) return false;
  }
  return true;
}
