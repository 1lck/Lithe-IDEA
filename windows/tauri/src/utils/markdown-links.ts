/**
 * Destination of a Markdown link in an Agent reply. Agents cite workspace
 * files as relative or absolute paths, often with a `:line` suffix or a
 * `#L12` anchor; those open in the editor instead of the system browser.
 *
 * This mirrors `AgentMarkdownLink` on macOS and stays pure so the renderer
 * and its tests share one classification.
 */

export interface MarkdownFileLink {
  kind: "file";
  path: string;
  line: number | null;
  /** Documents and extension-less files get a document icon, code gets a code icon. */
  document: boolean;
}

export type MarkdownLinkTarget = MarkdownFileLink | { kind: "github" } | { kind: "web" };

const WEB_SCHEMES = new Set(["http", "https", "mailto"]);
const NUMBER_SCHEMES = new Set(["tel", "sms", "fax", "facetime"]);
const DOCUMENT_EXTENSIONS = new Set([
  "md",
  "markdown",
  "mdx",
  "txt",
  "rst",
  "adoc",
  "pdf",
  "doc",
  "docx",
]);

function schemeOf(href: string): string | null {
  const match = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(href);
  return match === null ? null : (match[1] ?? "").toLowerCase();
}

function fileLocation(href: string): { path: string; line: number | null } | null {
  let raw = href;
  let line: number | null = null;

  if (raw.toLowerCase().startsWith("file://")) {
    try {
      const url = new URL(raw);
      const anchor = /^L(\d+)/.exec(url.hash.slice(1));
      if (anchor !== null) line = Number(anchor[1]);
      raw = decodeURIComponent(url.pathname);
    } catch {
      raw = raw.slice(7);
    }
    if (/^\/[A-Za-z]:\//.test(raw)) raw = raw.slice(1);
  }

  if (line === null) {
    const fragment = /#L(\d+)/.exec(raw);
    if (fragment !== null) {
      line = Number(fragment[1]);
      raw = raw.slice(0, fragment.index);
    }
  }

  try {
    raw = decodeURIComponent(raw);
  } catch {
    // Keep the original text when the escape sequence is malformed.
  }

  const suffix = /:(\d+)(?::\d+)?$/.exec(raw);
  if (suffix !== null) {
    line = line ?? Number(suffix[1]);
    raw = raw.slice(0, suffix.index);
  }

  if (raw.length === 0 || raw.startsWith("#")) return null;
  return { path: raw, line };
}

/** Classify a link as a workspace file, a GitHub page, or a plain web page. */
export function classifyMarkdownLink(href: string): MarkdownLinkTarget {
  const trimmed = href.trim();
  // A Windows drive letter is a path, not a URL scheme.
  const scheme = /^[A-Za-z]:[\\/]/.test(trimmed) ? null : schemeOf(trimmed);

  if (scheme !== null && WEB_SCHEMES.has(scheme)) {
    let host = "";
    try {
      host = new URL(trimmed).hostname.toLowerCase();
    } catch {
      // A malformed web URL still belongs to the system opener.
    }
    return host === "github.com" || host.endsWith(".github.com")
      ? { kind: "github" }
      : { kind: "web" };
  }

  const isPath =
    scheme === null ||
    scheme === "file" ||
    scheme.includes(".") ||
    (!NUMBER_SCHEMES.has(scheme) && /^[^/:]+:\d+(:\d+)?$/.test(trimmed));
  const location = isPath ? fileLocation(trimmed) : null;
  if (location === null) return { kind: "web" };

  const name = location.path.split(/[\\/]/).pop() ?? location.path;
  const dot = name.lastIndexOf(".");
  const extension = dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
  return {
    kind: "file",
    path: location.path,
    line: location.line,
    document: extension.length === 0 || DOCUMENT_EXTENSIONS.has(extension),
  };
}