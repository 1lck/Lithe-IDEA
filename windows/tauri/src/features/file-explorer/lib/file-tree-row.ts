export const FILE_TREE_BASE_INDENT = 10;
export const FILE_TREE_MIN_ROW_HEIGHT = 24;

const FILE_TREE_ROW_LINE_HEIGHT = 1.35;
const FILE_TREE_ROW_VERTICAL_CHROME = 6;

export function getFileTreeRowHeight(uiFontSize: number): number {
  const height = Math.max(
    FILE_TREE_MIN_ROW_HEIGHT,
    uiFontSize * FILE_TREE_ROW_LINE_HEIGHT + FILE_TREE_ROW_VERTICAL_CHROME,
  );

  return Number(height.toFixed(2));
}
