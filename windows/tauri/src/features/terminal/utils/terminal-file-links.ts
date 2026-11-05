import { homeDir } from "@tauri-apps/api/path";
import { stat } from "@tauri-apps/plugin-fs";
import { invoke } from "@/platform/tauri-core";

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

/** Providers whose files cannot be stat'ed from the webview. */
const PROVIDER_SCHEMES = ["remote", "wsl"];
const MAX_CANDIDATES_PER_LINE = 64;
const LEADING_TRIM_RE = /^[`"'(<[{]+/;
const TRAILING_TRIM_RE = /[`"')>\]},.;!:]+$/;

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

/**
 * Whether the path is a real file. Provider files cannot be checked here, so they only
 * count when the text carries an explicit `:line` location.
 */
async function fileExists(path: string, hasLocation: boolean): Promise<boolean> {
  if (isProviderPath(path)) return hasLocation;
  try {
    return (await stat(path)).isFile;
  } catch {
    return false;
  }
}

/**
 * Finds file links in one terminal line. Token boundaries (the hit regions) and the
 * existence check stay here; Core decides what each token means and where it points.
 * No extension list is consulted: a token is a link exactly when its target is a file.
 */
export async function findTerminalFileLinks(
  lineText: string,
  workspaceRoot: string | undefined,
): Promise<TerminalFileLink[]> {
  const tokens: Token[] = [];
  for (const match of lineText.matchAll(/\S+/g)) {
    const token = trimToken(match[0], match.index ?? 0);
    if (token.text) tokens.push(token);
    if (tokens.length === MAX_CANDIDATES_PER_LINE) break;
  }
  if (tokens.length === 0) return [];

  const { targets } = await invoke<{ targets: (CoreLinkTarget | null)[] }>(
    "terminal.parseLinkTarget",
    {
      texts: tokens.map((token) => token.text),
      baseDirectory: workspaceRoot,
      homeDirectory: await getHomeDirectory(),
      providerSchemes: PROVIDER_SCHEMES,
    },
  );

  const checks = tokens.map(async (token, index): Promise<TerminalFileLink | null> => {
    const target = targets[index];
    // Web links are handled by the web-links addon.
    if (target?.kind !== "file" || !target.explicit) return null;
    if (!(await fileExists(target.path, target.line !== null))) return null;
    return {
      ...token,
      path: target.path,
      line: target.line ?? undefined,
      column: target.column ?? undefined,
    };
  });
  return (await Promise.all(checks)).filter((link): link is TerminalFileLink => link !== null);
}
