/**
 * Workspace paths as ACP file references.
 *
 * The panel attaches project files by absolute path, while the protocol and the
 * shared host expect a `file:` URL with `/` separators. Encoding every segment
 * except a Windows drive letter keeps spaces, non-ASCII names, and the drive
 * prefix intact.
 */
export function agentFileUri(path: string): string {
  const normalized = path.replace(/\\/g, "/").trim();
  const segments = normalized.split("/").filter((segment) => segment.length > 0);
  const encoded = segments.map((segment, index) =>
    index === 0 && /^[A-Za-z]:$/.test(segment) ? segment : encodeURIComponent(segment),
  );
  return `file:///${encoded.join("/")}`;
}
