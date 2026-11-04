import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import type { FileChangeEvent } from "@/features/file-system/services/file-watcher-listener";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { emitGitChanged } from "../events/git-events";

/**
 * Working-tree file events reach this WebView through the workspace file
 * watcher; `.git` metadata has its own host (GitMetadataWatchHost). Bridge
 * repository-relevant working-tree changes into the Git event stream so the
 * Commit panel follows external edits, mirroring the macOS
 * `gitStateMayHaveChanged` batches from MacDirectoryWatcher.
 *
 * "external-file-change" is a passive source: `autoRefreshGitStatus` stays
 * authoritative and the workspace-indexing consumer ignores these events.
 */
export function GitWorkingTreeChangeHost() {
  useEffect(() => {
    const unlisten = listen<FileChangeEvent>("file-changed", ({ payload }) => {
      const { path, event_type: eventType } = payload;
      // A watcher rebuild carries no single-file meaning; the activation
      // refresh and the metadata host reconciliation cover the recovery.
      if (eventType === "rescan") return;
      // `.git` internals belong to the metadata watcher; forwarding them here
      // would only duplicate its batches.
      if (isInsideGitDirectory(path)) return;
      for (const runtime of workspaceRuntimeRegistry.getWorkspaces()) {
        if (runtime.status !== "ready") continue;
        const repositories = runtime.stores.get("git-repository")?.getState() as
          | { availableRepoPaths?: string[]; activeRepoPath?: string | null }
          | undefined;
        // A manual repository can already be listed in availableRepoPaths.
        const repoPaths = new Set(
          [
            ...(repositories?.availableRepoPaths ?? []),
            repositories?.activeRepoPath ?? undefined,
          ].filter(Boolean) as string[],
        );
        for (const repoPath of repoPaths) {
          if (!isPathInsideRepository(path, repoPath)) continue;
          emitGitChanged({
            repoPath,
            filePath: path,
            scopes: ["working-tree"],
            source: "external-file-change",
          });
        }
      }
    });
    return () => {
      void unlisten
        .then((unsubscribe) => unsubscribe())
        .catch((error) => console.error("Could not detach working-tree change listener:", error));
    };
  }, []);
  return null;
}

function isInsideGitDirectory(path: string): boolean {
  const segments = path.replace(/\\/g, "/").split("/");
  return segments.slice(1).some((segment) => segment === ".git");
}

/** Same normalization strength as the repository overlap check in git-events. */
function isPathInsideRepository(path: string, repoPath: string): boolean {
  const normalizedPath = path.replace(/\\/g, "/").replace(/\/+$/, "");
  const normalizedRepo = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
  return normalizedPath === normalizedRepo || normalizedPath.startsWith(`${normalizedRepo}/`);
}
