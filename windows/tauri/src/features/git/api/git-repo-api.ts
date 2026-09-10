import { invoke as tauriInvoke } from "@/platform/tauri-core";

interface RepositoryDiscoveryCacheEntry {
  discoveredAt: number;
  repoPath: string | null;
}

interface WorkspaceRepositoriesResponse {
  repositories?: Array<{ path?: string | null }>;
}

const repoDiscoveryCache = new Map<string, RepositoryDiscoveryCacheEntry>();
const workspaceRepoDiscoveryCache = new Map<string, { discoveredAt: number; repos: string[] }>();
const inFlightRepoDiscoveries = new Map<string, Promise<string | null>>();
const inFlightWorkspaceDiscoveries = new Map<string, Promise<string[]>>();
let discoveryGeneration = 0;

const NOT_REPO_PATTERNS = [
  "failed to open repository",
  "not a git repository",
  "could not find repository",
  "class=repository",
  "code=notfound",
];

const WORKSPACE_REPO_CACHE_TTL_MS = 5 * 60_000;
const REPO_CACHE_TTL_MS = 5 * 60_000;
const NEGATIVE_REPO_CACHE_TTL_MS = 5_000;
function normalizePath(path: string): string {
  if (path.startsWith("wsl://") || path.startsWith("remote://")) {
    const [scheme, rest] = path.split("://");
    const collapsedRest = (rest ?? "").replace(/\/{2,}/g, "/");
    const normalized = `${scheme}://${collapsedRest}`;
    return normalized.length > `${scheme}://`.length + 1
      ? normalized.replace(/\/+$/, "")
      : normalized;
  }

  const unixPath = path.replace(/\\/g, "/");
  const collapsed = unixPath.replace(/\/{2,}/g, "/");
  return collapsed.length > 1 ? collapsed.replace(/\/+$/, "") : collapsed;
}

function isAbsolutePath(path: string): boolean {
  return (
    path.startsWith("/") ||
    path.startsWith("wsl://") ||
    path.startsWith("remote://") ||
    /^[A-Za-z]:\//.test(path.replace(/\\/g, "/"))
  );
}

function joinPath(basePath: string, childPath: string): string {
  if (!basePath) return normalizePath(childPath);
  const base = normalizePath(basePath);
  const child = childPath.replace(/^[/\\]+/, "");
  return normalizePath(`${base}/${child}`);
}

function parentPath(path: string): string {
  const normalized = normalizePath(path);
  const separatorIndex = normalized.lastIndexOf("/");
  if (separatorIndex < 0) return normalized;
  if (separatorIndex === 2 && /^[A-Za-z]:\//.test(normalized)) {
    return normalized.slice(0, separatorIndex + 1);
  }
  return separatorIndex === 0 ? "/" : normalized.slice(0, separatorIndex);
}

function toRelativePath(from: string, to: string): string {
  const normalizedFrom = normalizePath(from);
  const normalizedTo = normalizePath(to);
  const prefix = `${normalizedFrom}/`;
  if (normalizedTo.startsWith(prefix)) {
    return normalizedTo.slice(prefix.length);
  }
  if (normalizedTo === normalizedFrom) {
    return "";
  }
  return normalizedTo;
}


export function normalizeRepositoryPath(path: string): string {
  return normalizePath(path);
}

export function isNotGitRepositoryError(error: unknown): boolean {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : (() => {
            try {
              return JSON.stringify(error);
            } catch {
              return String(error);
            }
          })();

  const normalized = message.toLowerCase();
  return NOT_REPO_PATTERNS.some((pattern) => normalized.includes(pattern));
}

async function discoverRepo(path: string): Promise<string | null> {
  const normalizedPath = normalizePath(path);
  const cached = repoDiscoveryCache.get(normalizedPath);
  if (cached) {
    const ttl = cached.repoPath ? REPO_CACHE_TTL_MS : NEGATIVE_REPO_CACHE_TTL_MS;
    if (Date.now() - cached.discoveredAt < ttl) {
      return cached.repoPath;
    }
    repoDiscoveryCache.delete(normalizedPath);
  }

  const existingRequest = inFlightRepoDiscoveries.get(normalizedPath);
  if (existingRequest) return existingRequest;

  const generation = discoveryGeneration;
  const request = tauriInvoke<string | null>("git_discover_repo", {
    path: normalizedPath,
  })
    .then((discovered) => {
      const repoPath = discovered ? normalizePath(discovered) : null;
      if (generation === discoveryGeneration) {
        repoDiscoveryCache.set(normalizedPath, {
          discoveredAt: Date.now(),
          repoPath,
        });
      }
      return repoPath;
    })
    .catch((error) => {
      if (isNotGitRepositoryError(error)) {
        if (generation === discoveryGeneration) {
          repoDiscoveryCache.set(normalizedPath, {
            discoveredAt: Date.now(),
            repoPath: null,
          });
        }
        return null;
      }
      throw error;
    })
    .finally(() => {
      if (inFlightRepoDiscoveries.get(normalizedPath) === request) {
        inFlightRepoDiscoveries.delete(normalizedPath);
      }
    });

  inFlightRepoDiscoveries.set(normalizedPath, request);
  return request;
}

export async function resolveRepositoryPath(repoPath: string): Promise<string | null> {
  return discoverRepo(repoPath);
}

export async function resolveRepositoryPathOrThrow(repoPath: string): Promise<string> {
  const resolvedRepoPath = await resolveRepositoryPath(repoPath);
  if (!resolvedRepoPath) {
    throw new Error("Not a Git repository");
  }
  return resolvedRepoPath;
}

export async function resolveRepositoryForFile(
  repoPath: string,
  filePath: string,
): Promise<{ repoPath: string; filePath: string } | null> {
  const absoluteFilePath = isAbsolutePath(filePath) ? filePath : joinPath(repoPath, filePath);
  let discoveredRepo: string | null;
  try {
    discoveredRepo = await discoverRepo(parentPath(absoluteFilePath));
  } catch (error) {
    const fallbackRepo = await discoverRepo(repoPath);
    const normalizedFallbackRepo = fallbackRepo ? normalizePath(fallbackRepo) : null;
    const normalizedAbsoluteFile = normalizePath(absoluteFilePath);
    const belongsToFallbackRepo =
      normalizedFallbackRepo !== null &&
      (normalizedAbsoluteFile === normalizedFallbackRepo ||
        normalizedAbsoluteFile.startsWith(`${normalizedFallbackRepo}/`));

    if (!belongsToFallbackRepo) {
      throw error;
    }
    discoveredRepo = normalizedFallbackRepo;
  }

  if (!discoveredRepo) {
    return null;
  }

  const normalizedAbsoluteFile = normalizePath(absoluteFilePath);
  let relativePath = normalizePath(toRelativePath(discoveredRepo, normalizedAbsoluteFile));

  if (!relativePath || relativePath === ".") {
    relativePath = normalizePath(filePath);
  }

  return {
    repoPath: discoveredRepo,
    filePath: relativePath,
  };
}

export async function discoverWorkspaceRepositories(
  workspacePath: string | readonly string[],
  options?: { force?: boolean },
): Promise<string[]> {
  const normalizedWorkspacePaths = [...new Set((
    Array.isArray(workspacePath) ? workspacePath : [workspacePath]
  )
    .map((path) => normalizePath(path))
    .filter(Boolean))];
  if (normalizedWorkspacePaths.length === 0) return [];
  const normalizedWorkspacePath = [...new Set(normalizedWorkspacePaths)].join("\0");

  const force = options?.force ?? false;
  if (!force) {
    const cached = workspaceRepoDiscoveryCache.get(normalizedWorkspacePath);
    if (cached && Date.now() - cached.discoveredAt < WORKSPACE_REPO_CACHE_TTL_MS) {
      return cached.repos;
    }

    const existingRequest = inFlightWorkspaceDiscoveries.get(normalizedWorkspacePath);
    if (existingRequest) {
      return existingRequest;
    }
  }

  const generation = discoveryGeneration;
  const request = discoverWorkspaceRepositoriesFromCore(normalizedWorkspacePaths).then((repos) => {
    // An older forced scan must not overwrite the newest result in the cache.
    if (generation === discoveryGeneration && inFlightWorkspaceDiscoveries.get(normalizedWorkspacePath) === request) {
      workspaceRepoDiscoveryCache.set(normalizedWorkspacePath, { discoveredAt: Date.now(), repos });
    }
    return repos;
  }).finally(() => {
    if (inFlightWorkspaceDiscoveries.get(normalizedWorkspacePath) === request) {
      inFlightWorkspaceDiscoveries.delete(normalizedWorkspacePath);
    }
  });
  inFlightWorkspaceDiscoveries.set(normalizedWorkspacePath, request);
  return request;
}

async function discoverWorkspaceRepositoriesFromCore(
  normalizedWorkspacePaths: readonly string[],
): Promise<string[]> {
  const repositoryPaths = new Set<string>();
  const repositoriesByWorkspace = await Promise.all(
    normalizedWorkspacePaths.map(async (workspacePath) => {
      const response = await tauriInvoke<WorkspaceRepositoriesResponse>(
        "git_discover_workspace_repos",
        {
          workspacePath,
        },
      );
      const paths = Array.isArray(response.repositories)
        ? response.repositories
            .map((repository) =>
              typeof repository?.path === "string" ? normalizePath(repository.path) : null,
            )
            .filter((path): path is string => !!path)
        : [];
      return paths;
    }),
  );

  const orderedRepositories: string[] = [];
  for (const repositories of repositoriesByWorkspace) {
    for (const repositoryPath of repositories) {
      if (!repositoryPaths.has(repositoryPath)) {
        repositoryPaths.add(repositoryPath);
        orderedRepositories.push(repositoryPath);
      }
    }
  }
  return orderedRepositories;
}


export function clearRepositoryDiscoveryCache(): void {
  discoveryGeneration += 1;
  repoDiscoveryCache.clear();
  workspaceRepoDiscoveryCache.clear();
  inFlightRepoDiscoveries.clear();
  inFlightWorkspaceDiscoveries.clear();
}
