/** Normalizes path components before applying the workspace boundary check. */
export function normalizeWorkspacePath(value: string): string | null {
  const path = value.replace(/\\/g, "/");
  const prefix = path.startsWith("//")
    ? "//"
    : /^[A-Za-z]:\//.test(path)
      ? path.slice(0, 3)
      : path.startsWith("/")
        ? "/"
        : null;
  if (!prefix) return null;
  const parts: string[] = [];
  for (const part of path.slice(prefix.length).split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return null;
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  const normalized = `${prefix}${parts.join("/")}`.replace(/\/$/, "");
  return normalized || prefix;
}

export function pathIsInsideWorkspace(path: string, root: string): boolean {
  const normalized = normalizeWorkspacePath(path);
  const normalizedRoot = normalizeWorkspacePath(root);
  if (!normalized || !normalizedRoot || normalized === normalizedRoot) return false;
  const candidate = normalized.toLowerCase();
  const workspace = normalizedRoot.toLowerCase();
  return candidate !== workspace && candidate.startsWith(`${workspace}/`);
}
