import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@/platform/tauri-core";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { emitGitChanged, isGitChangeRelevant } from "../events/git-events";
import { useRepositoryStore } from "../stores/git-repository.store";
import { createGitRefreshQueue } from "../services/git-operation-coordinator";

interface GitMetadataChange {
  repositoryRoots: string[];
  metadataLinkChanged: boolean;
}

export function GitMetadataWatchHost() {
  const workspaceId = useActiveWorkspaceId();
  const activeRepoPath = useRepositoryStore((state) => state.activeRepoPath);
  const availableRepoPaths = useRepositoryStore((state) => state.availableRepoPaths);
  const projectPath = useProjectStore((state) => state.rootFolderPath);
  const pathsKey = JSON.stringify(
    availableRepoPaths.length
      ? availableRepoPaths
      : [activeRepoPath ?? projectPath].filter(Boolean),
  );
  useEffect(() => {
    const repoPaths = JSON.parse(pathsKey) as string[];
    if (!repoPaths.length) return;
    let current = true;
    const watchIds = new Map<string, string>();
    const installs = createGitRefreshQueue();
    const release = (watchId: string) =>
      invoke("unwatch_git_repository", { watchId }).catch((error) =>
        console.error("Could not release Git metadata watch:", error),
      );
    const install = (repoPath: string) =>
      installs.run(repoPath, async () => {
        const previous = watchIds.get(repoPath);
        if (previous) await release(previous);
        if (!current) return;
        const watchId = watchIds.get(repoPath) ?? crypto.randomUUID();
        watchIds.set(repoPath, watchId);
        await invoke("watch_git_repository", { repoPath, watchId }).catch((error) => {
          if (current) console.error("Could not watch Git metadata:", error);
        });
        // An install can finish after unmount's unwatch, so release it again.
        if (!current) await release(watchId);
      });
    const listener = listen<GitMetadataChange>("git-metadata-changed", ({ payload }) => {
      if (!current) return;
      for (const root of payload.repositoryRoots) {
        emitGitChanged({
          repoPath: root,
          scopes: ["working-tree", "history", "refs", "stashes", "repository"],
          source: "external-git-change",
        });
      }
      if (payload.metadataLinkChanged && payload.repositoryRoots.length)
        for (const repoPath of repoPaths) {
          if (
            payload.repositoryRoots.some((root) =>
              isGitChangeRelevant({ repoPath: root }, repoPath),
            )
          )
            void install(repoPath);
        }
    });
    void listener
      .then(() => {
        if (current) return Promise.all(repoPaths.map(install));
      })
      .catch((error) => console.error("Could not receive Git metadata changes:", error));
    return () => {
      current = false;
      installs.clear();
      void listener
        .then((unlisten) => unlisten())
        .catch((error) => console.error("Could not release Git metadata listener:", error));
      for (const watchId of watchIds.values()) void release(watchId);
    };
  }, [workspaceId, pathsKey]);
  return null;
}
