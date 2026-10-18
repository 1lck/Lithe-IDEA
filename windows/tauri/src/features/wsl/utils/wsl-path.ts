export interface WslPathInfo {
  distro: string;
  linuxPath: string;
}

const WSL_PREFIX = "wsl://";

export function isWslPath(path: string | undefined | null): path is string {
  return typeof path === "string" && path.startsWith(WSL_PREFIX);
}

export function normalizeWslLinuxPath(path: string | undefined | null): string {
  const trimmed = (path ?? "").trim();
  if (!trimmed || trimmed === "~") return "/";

  let normalized = trimmed.replace(/\\/g, "/");
  if (!normalized.startsWith("/")) {
    normalized = `/${normalized}`;
  }

  while (normalized.includes("//")) {
    normalized = normalized.replace(/\/{2,}/g, "/");
  }

  const parts: string[] = [];
  for (const part of normalized.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      parts.pop();
      continue;
    }
    parts.push(part);
  }

  return parts.length > 0 ? `/${parts.join("/")}` : "/";
}

export function parseWslPath(path: string): WslPathInfo | null {
  if (!isWslPath(path)) return null;

  const rest = path.slice(WSL_PREFIX.length);
  const separatorIndex = rest.indexOf("/");
  const distro = (separatorIndex === -1 ? rest : rest.slice(0, separatorIndex)).trim();

  if (!distro) return null;

  return {
    distro,
    linuxPath: normalizeWslLinuxPath(separatorIndex === -1 ? "/" : rest.slice(separatorIndex)),
  };
}

export function buildWslPath(distro: string, linuxPath = "/"): string {
  return `${WSL_PREFIX}${distro.trim()}${normalizeWslLinuxPath(linuxPath)}`;
}

export function getWslShellId(distro: string): string {
  return `wsl:${distro}`;
}

export function joinWslPath(path: string, segment: string): string {
  const info = parseWslPath(path);
  if (!info) return path;

  const cleanSegment = segment.replace(/^\/+|\/+$/g, "");
  if (!cleanSegment) return buildWslPath(info.distro, info.linuxPath);

  return buildWslPath(
    info.distro,
    info.linuxPath === "/" ? `/${cleanSegment}` : `${info.linuxPath}/${cleanSegment}`,
  );
}

export function resolveWslTargetPath(sourcePath: string, targetPath: string): string | null {
  const info = parseWslPath(sourcePath);
  if (!info) return null;

  const target = targetPath.trim();
  if (!target) return buildWslPath(info.distro, info.linuxPath);
  if (target.startsWith("/")) return buildWslPath(info.distro, target);

  const parentPath = info.linuxPath.slice(0, info.linuxPath.lastIndexOf("/")) || "/";
  return buildWslPath(info.distro, `${parentPath}/${target}`);
}

export function getWslDisplayPath(path: string): string {
  const info = parseWslPath(path);
  return info ? `${info.distro}:${info.linuxPath}` : path;
}

/**
 * Translate a Windows filesystem path into the path a WSL distribution can open.
 *
 * WSL mounts each drive under `/mnt/<letter>` by default, so `C:\work\a.txt`
 * becomes `/mnt/c/work/a.txt`. A shell inside the distribution cannot open the
 * Windows form at all: it treats the backslashes as ordinary characters in a
 * relative filename.
 *
 * Returns null when the path cannot be translated reliably — a UNC share is not
 * mounted at a predictable location — so callers can keep the original instead of
 * inserting a path that silently points nowhere.
 */
export function windowsPathToWslPath(path: string): string | null {
  const driveMatch = /^([A-Za-z]):[\\/](.*)$/.exec(path);
  if (driveMatch) {
    const drive = driveMatch[1].toLowerCase();
    const rest = driveMatch[2].replace(/\\/g, "/");
    return rest ? `/mnt/${drive}/${rest}` : `/mnt/${drive}`;
  }

  // A path already written in Linux form needs no translation.
  if (path.startsWith("/")) return path;

  return null;
}
