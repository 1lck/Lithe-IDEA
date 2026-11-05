import { homeDir } from "@tauri-apps/api/path";
import { stat } from "@tauri-apps/plugin-fs";
import { invoke } from "@/platform/tauri-core";
import { parseRemotePath } from "@/features/remote/utils/remote-path";
import { parseWslPath } from "@/features/wsl/utils/wsl-path";

export interface TerminalFileLink {
  text: string;
  path: string;
  line?: number;
  column?: number;
  startIndex: number;
  endIndex: number;
}

type CoreLinkTarget =
  | { kind: "file"; path: string; line: number | null; column: number | null; explicit: boolean }
  | { kind: "external"; url: string };

interface Token {
  text: string;
  startIndex: number;
  endIndex: number;
}

/** Providers whose files cannot be stat'ed from the webview; they are checked by listing the parent. */
const PROVIDER_SCHEMES = ["remote", "wsl"];
const MAX_CANDIDATES_PER_LINE = 64;
const CACHE_LIMIT = 128;
const CACHE_TTL_MS = 2000;
const LEADING_TRIM_RE = /^[`"'(<[{]+/;
const TRAILING_TRIM_RE = /[`"')>\]},.;!:]+$/;

interface DirectoryEntry {
  name: string;
  is_dir: boolean;
}

export interface TerminalLinkDeps {
  now: () => number;
  statFile: (path: string) => Promise<boolean>;
  listDirectory: (provider: string) => Promise<DirectoryEntry[]>;
  resolveTargets: (
    texts: string[],
    baseDirectory: string | undefined,
  ) => Promise<(CoreLinkTarget | null)[]>;
}

let homeDirectory: Promise<string | undefined> | undefined;
function getHomeDirectory(): Promise<string | undefined> {
  homeDirectory ??= homeDir().catch(() => undefined);
  return homeDirectory;
}

/** Hit region of a whitespace-delimited token without surrounding punctuation. */
function trimToken(rawToken: string, tokenStart: number): Token {
  let text = rawToken;
  let startIndex = tokenStart;
  const leading = text.match(LEADING_TRIM_RE)?.[0];
  if (leading) {
    text = text.slice(leading.length);
    startIndex += leading.length;
  }
  text = text.replace(TRAILING_TRIM_RE, "");
  return { text, startIndex, endIndex: startIndex + text.length };
}

function isProviderPath(path: string): boolean {
  return PROVIDER_SCHEMES.some((scheme) => path.toLowerCase().startsWith(`${scheme}://`));
}

/** Small bounded cache with a short TTL that also shares in-flight requests. */
class TtlCache<T> {
  private readonly entries = new Map<string, { at: number; value: Promise<T> }>();
  constructor(private readonly now: () => number) {}

  get(key: string, load: () => Promise<T>): Promise<T> {
    const hit = this.entries.get(key);
    if (hit && this.now() - hit.at < CACHE_TTL_MS) {
      this.entries.delete(key);
      this.entries.set(key, hit); // refresh LRU order
      return hit.value;
    }
    const value = load();
    this.entries.delete(key);
    this.entries.set(key, { at: this.now(), value });
    // A failed load must not be remembered.
    value.catch(() => {
      if (this.entries.get(key)?.value === value) this.entries.delete(key);
    });
    while (this.entries.size > CACHE_LIMIT) {
      this.entries.delete(this.entries.keys().next().value as string);
    }
    return value;
  }
}

function splitParent(path: string): { parent: string; name: string } | null {
  const index = path.lastIndexOf("/");
  if (index < 0) return null;
  const name = path.slice(index + 1);
  if (!name) return null;
  const parent = path.slice(0, index);
  return { parent: parent.endsWith("://") || parent.match(/^[a-z]+:\/\/[^/]+$/i) ? `${parent}/` : parent, name };
}

async function defaultListDirectory(provider: string): Promise<DirectoryEntry[]> {
  const remote = parseRemotePath(provider);
  if (remote) {
    return invoke<DirectoryEntry[]>("ssh_read_directory", {
      connectionId: remote.connectionId,
      path: remote.remotePath,
    });
  }
  const wsl = parseWslPath(provider);
  if (!wsl) return [];
  return invoke<DirectoryEntry[]>("wsl_read_directory", {
    distro: wsl.distro,
    path: wsl.linuxPath,
  });
}

export const defaultTerminalLinkDeps: TerminalLinkDeps = {
  now: () => performance.now(),
  statFile: async (path) => {
    try {
      return (await stat(path)).isFile;
    } catch {
      return false;
    }
  },
  listDirectory: defaultListDirectory,
  resolveTargets: async (texts, baseDirectory) =>
    (
      await invoke<{ targets: (CoreLinkTarget | null)[] }>("terminal.parseLinkTarget", {
        texts,
        baseDirectory,
        homeDirectory: await getHomeDirectory(),
        providerSchemes: PROVIDER_SCHEMES,
      })
    ).targets,
};

/**
 * Builds a link finder. Token boundaries (the hit regions) and existence checks stay here;
 * Core decides what each token means. No extension list is consulted: a token is a link
 * exactly when its target is a file. Local files are stat'ed; remote and WSL files are
 * looked up in a listing of their parent directory, the same adapter the file tree uses.
 * Results are cached per (working directory, line text) for a short time, and identical
 * in-flight requests are shared, so hovering around one line does not repeat the checks.
 */
export function createTerminalFileLinkFinder(deps: TerminalLinkDeps) {
  const lines = new TtlCache<TerminalFileLink[]>(deps.now);
  const directories = new TtlCache<DirectoryEntry[]>(deps.now);

  async function exists(path: string): Promise<boolean> {
    if (!isProviderPath(path)) return deps.statFile(path);
    const parts = splitParent(path);
    if (!parts) return false;
    try {
      const entries = await directories.get(parts.parent, () => deps.listDirectory(parts.parent));
      return entries.some((entry) => entry.name === parts.name && !entry.is_dir);
    } catch {
      return false;
    }
  }

  async function compute(lineText: string, workspaceRoot: string | undefined) {
    const tokens: Token[] = [];
    for (const match of lineText.matchAll(/\S+/g)) {
      const token = trimToken(match[0], match.index ?? 0);
      if (token.text) tokens.push(token);
      if (tokens.length === MAX_CANDIDATES_PER_LINE) break;
    }
    if (tokens.length === 0) return [];
    const targets = await deps.resolveTargets(
      tokens.map((token) => token.text),
      workspaceRoot,
    );
    const checks = tokens.map(async (token, index): Promise<TerminalFileLink | null> => {
      const target = targets[index];
      // Web links are handled by the web-links addon.
      if (target?.kind !== "file" || !target.explicit) return null;
      if (!(await exists(target.path))) return null;
      return {
        ...token,
        path: target.path,
        line: target.line ?? undefined,
        column: target.column ?? undefined,
      };
    });
    return (await Promise.all(checks)).filter((link): link is TerminalFileLink => link !== null);
  }

  return (lineText: string, workspaceRoot: string | undefined) =>
    lines.get(`${workspaceRoot ?? ""}\u0000${lineText}`, () => compute(lineText, workspaceRoot));
}

export const findTerminalFileLinks = createTerminalFileLinkFinder(defaultTerminalLinkDeps);
