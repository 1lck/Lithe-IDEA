import { normalizePath as normalizeFilePath, stripTrailingPathSeparators } from "../../../utils/path-helpers.ts";

export class UnsupportedGitPathError extends Error {
  constructor() {
    super("Git does not support Windows paths requiring verbatim semantics (trailing dots/spaces, reserved names or device namespaces)");
    this.name = "UnsupportedGitPathError";
  }
}

export function normalizeRepositoryPath(path: string): string {
  if (path.startsWith("wsl://") || path.startsWith("remote://")) {
    const [scheme, rest] = path.split("://");
    const collapsedRest = (rest ?? "").replace(/\/{2,}/g, "/");
    const normalized = `${scheme}://${collapsedRest}`;
    return normalized.length > `${scheme}://`.length + 1
      ? normalized.replace(/\/+$/, "")
      : normalized;
  }

  // UI comparison/rendering must remain total. Preserve unsupported input
  // verbatim so the operation boundary can report it without aliasing a sibling.
  if (isUnsupportedWindowsGitPath(path)) return path;
  const unixPath = normalizeFilePath(path);
  const collapsed = unixPath.replace(/\/{2,}/g, "/");
  // UNC repository identifiers must retain their network-root separator.
  const normalized = unixPath.startsWith("//") ? `/${collapsed}` : collapsed;
  return stripTrailingPathSeparators(normalized);
}

function isUnsupportedWindowsGitPath(path: string): boolean {
  if (path.startsWith("wsl://") || path.startsWith("remote://")) return false;
  const nativePath = path.replace(/\\/g, "/");
  if (!/^(?:[A-Za-z]:|\/\/)/.test(nativePath)) return false;
  const verbatim = nativePath.startsWith("//?/");
  if (nativePath.startsWith("//./") || (verbatim
    && !/^\/\/\?\/(?:[A-Za-z]:\/|UNC\/[^/]+\/[^/]+)/i.test(nativePath))) return true;
  const ordinaryPath = normalizeFilePath(path);
  // UNC server/share names are routing identifiers, not local file components.
  const components = ordinaryPath.startsWith("//")
    ? ordinaryPath.slice(2).split("/").filter(Boolean).slice(2)
    : ordinaryPath.split("/").slice(1);
  return components.some((part) => {
    if (part === "." || part === "..") return verbatim;
    return /[. ]$/.test(part)
      || /^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)/i.test(part);
  });
}

export function normalizeGitOperationPath(path: string): string {
  if (isUnsupportedWindowsGitPath(path)) throw new UnsupportedGitPathError();
  return normalizeRepositoryPath(path);
}
