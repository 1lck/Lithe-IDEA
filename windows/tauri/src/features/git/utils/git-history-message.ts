export function splitGitCommitMessage(message: string): { title: string; body: string } {
  const normalized = message.replace(/\r\n/g, "\n");
  const firstNewline = normalized.indexOf("\n");
  if (firstNewline < 0) return { title: normalized, body: "" };
  return {
    title: normalized.slice(0, firstNewline),
    body: normalized.slice(firstNewline + 1).replace(/^\n/, ""),
  };
}

export function joinGitCommitMessage(title: string, body: string): string {
  return body ? `${title}\n\n${body}` : title;
}

export function isGitHeadCommit(commit: { decorations: string }): boolean {
  return commit.decorations.split(",").some((decoration) => {
    const value = decoration.trim();
    return value === "HEAD" || value.startsWith("HEAD -> ");
  });
}
