export interface InlineGitBlameLayoutIdentity {
  filePath: string;
  lineNumber: number;
  column: number;
  commitHash: string;
  content: string;
}

/**
 * The column belongs to the layout identity. Editing the same uncommitted line
 * keeps the commit and label unchanged, but the hint still has to move to the
 * new end of line instead of staying at the old column over newly typed text.
 */
export function inlineGitBlameLayoutKey(identity: InlineGitBlameLayoutIdentity): string {
  return JSON.stringify([
    identity.filePath,
    identity.lineNumber,
    identity.column,
    identity.commitHash,
    identity.content,
  ]);
}
