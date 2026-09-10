import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@/platform/tauri-core";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { emitGitChanged, isGitChangeRelevant } from "../events/git-events";
import { useRepositoryStore } from "../stores/git-repository.store";

interface GitMetadataChange {
  repositoryRoots: string[];
  metadataLinkChanged: boolean;
}

export function GitMetadataWatchHost() {
  const workspaceId = useActiveWorkspaceId();
  const activeRepoPath = useRepositoryStore((state) => state.activeRepoPath);
  const projectPath = useProjectStore((state) => state.rootFolderPath);
  const repoPath = activeRepoPath ?? projectPath;
  useEffect(() => {
    if (!repoPath) return;
    let current = true;
    let watchId: string | null = null;
    const install = () => {
      watchId = crypto.randomUUID();
      return invoke("watch_git_repository", { repoPath, watchId }).catch((error) => {
        if (current) console.error("Could not watch Git metadata:", error);
      });
    };
    const listener = listen<GitMetadataChange>("git-metadata-changed", ({ payload }) => {
      if (!current) return;
      for (const root of payload.repositoryRoots) {
        emitGitChanged({
          repoPath: root,
          scopes: ["working-tree", "history", "refs", "stashes", "repository"],
          source: "external-git-change",
        });
      }
      if (
        payload.metadataLinkChanged &&
        payload.repositoryRoots.some((root) => isGitChangeRelevant({ repoPath: root }, repoPath))
      )
        void install();
    });
    void listener
      .then(() => {
        if (current) return install();
      })
      .catch((error) => console.error("Could not receive Git metadata changes:", error));
    return () => {
      current = false;
      void listener
        .then((unlisten) => unlisten())
        .catch((error) => console.error("Could not release Git metadata listener:", error));
      if (watchId)
        void invoke("unwatch_git_repository", { watchId }).catch((error) =>
          console.error("Could not release Git metadata watch:", error),
        );
    };
  }, [workspaceId, repoPath]);
  return null;
}
