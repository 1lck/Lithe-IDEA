import { useFileWatcherStore } from "@/features/file-system/stores/file-watcher.store";
import { joinPath } from "@/utils/path-helpers";
import type { MavenModule, MavenProject } from "../types/maven.types";

export interface MavenPomWatchOperations {
  startWatching: (path: string) => Promise<boolean>;
  stopWatching: (path: string) => Promise<boolean>;
}

export function mavenPomPaths(root: string, project: MavenProject): Set<string> {
  const paths = new Set<string>();

  const appendPomPath = (module: Pick<MavenModule, "relativePath" | "modules">) => {
    const relativePath = module.relativePath === "." ? "" : module.relativePath;
    const segments = relativePath.split(/[\\/]+/).filter(Boolean);
    paths.add(joinPath(root, ...segments, "pom.xml"));
    for (const child of module.modules) appendPomPath(child);
  };

  appendPomPath(project);
  return paths;
}

export async function reconcileMavenPomWatches(
  watchedPaths: ReadonlySet<string>,
  desiredPaths: ReadonlySet<string>,
  operations: MavenPomWatchOperations,
): Promise<Set<string>> {
  const nextWatchedPaths = new Set(watchedPaths);

  for (const path of [...watchedPaths].filter((path) => !desiredPaths.has(path)).sort()) {
    try {
      if (await operations.stopWatching(path)) nextWatchedPaths.delete(path);
    } catch (error) {
      console.error("Failed to stop Maven POM watch:", path, error);
    }
  }

  // Calling the idempotent adapter for every desired path repairs registrations
  // cleared by workspace shutdown without coupling this feature to watcher state.
  for (const path of [...desiredPaths].sort()) {
    try {
      if (await operations.startWatching(path)) nextWatchedPaths.add(path);
    } catch (error) {
      console.error("Failed to start Maven POM watch:", path, error);
    }
  }

  return nextWatchedPaths;
}

export function createMavenPomWatchOperations(workspaceId: string): MavenPomWatchOperations {
  return {
    startWatching: (path) =>
      useFileWatcherStore.getStore(workspaceId).getState().actions.startWatching(path),
    stopWatching: (path) =>
      useFileWatcherStore.getStore(workspaceId).getState().actions.stopWatching(path),
  };
}
