import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@/platform/tauri-core";
import { emitGitChanged, type GitChange, isGitChangeRelevant } from "../events/git-events";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { canUseNativeFileSearch } from "@/features/file-search/utils/file-search-paths";
import { getPathIdentity } from "@/utils/path-helpers";

interface GitMetadataChange {
  repositoryRoots: string[];
  metadataLinkChanged: boolean;
  /** Only the index was rewritten: staging changed, commits and refs did not. */
  indexOnly?: boolean;
}

/**
 * The repository change one native metadata batch stands for. An index-only
 * batch refreshes working-tree state; it is not reported as a history change,
 * because tools rewrite the index constantly while a project opens and history
 * consumers (blame, log) would otherwise reload on every rewrite.
 */
export function gitChangeForMetadata(
  repoPath: string,
  change: Pick<GitMetadataChange, "indexOnly">,
): GitChange {
  return {
    repoPath,
    scopes: change.indexOnly
      ? ["working-tree"]
      : ["working-tree", "history", "refs", "stashes", "repository"],
    source: "external-git-change",
  };
}

/** App-mounted controller; registrations follow runtime membership, never the active tab. */
export function GitMetadataWatchHost() {
  useEffect(() => {
    let stopped = false;
    let listening = false;
    type Entry = { runtimeId: string; repoPath: string; watchId: string; active: boolean; invalidate: () => void };
    const entries = new Map<string, Entry>();
    const runtimeIds = new WeakMap<object, string>();
    const release = (entry: Entry) => invoke("unwatch_git_repository", {
      runtimeId: entry.runtimeId, watchId: entry.watchId,
    }).catch((error) => console.error("Could not release Git metadata watch:", error));
    const retire = (key: string, entry: Entry) => {
      entry.active = false;
      entries.delete(key);
      void release(entry);
    };
    const reconcile = () => {
      if (stopped || !listening) return;
      const wanted = new Map<string, {runtimeId: string; repoPath: string; invalidate: () => void}>();
      for (const runtime of workspaceRuntimeRegistry.getWorkspaces()) {
        if (runtime.status !== "ready") continue;
        let runtimeId = runtimeIds.get(runtime);
        if (!runtimeId) { runtimeId = crypto.randomUUID(); runtimeIds.set(runtime, runtimeId); }
        const repositories = runtime.stores.get("git-repository")?.getState() as
          { availableRepoPaths: string[]; activeRepoPath?: string | null } | undefined;
        const files = runtime.stores.get("file-system")?.getState() as
          { rootFolderPath?: string; workspaceFolders: {path: string}[] } | undefined;
        const paths = new Set([
          ...(repositories?.availableRepoPaths ?? []), repositories?.activeRepoPath,
          files?.rootFolderPath ?? runtime.descriptor.path,
          ...(files?.workspaceFolders.map((folder) => folder.path) ?? []),
        ]);
        for (const repoPath of paths) {
          if (!canUseNativeFileSearch(repoPath)) continue;
          wanted.set(JSON.stringify([runtimeId, getPathIdentity(repoPath)]), {runtimeId, repoPath, invalidate: () => runtime.invalidateIndexing?.()});
        }
      }
      for (const [key, entry] of entries) if (!wanted.has(key)) retire(key, entry);
      for (const [key, target] of wanted) {
        if (entries.has(key)) continue;
        const entry: Entry = {...target, watchId: crypto.randomUUID(), active: true};
        entries.set(key, entry);
        void invoke("watch_git_repository", {
          repoPath: entry.repoPath, runtimeId: entry.runtimeId, watchId: entry.watchId,
        }).then(() => { if (entry.active) entry.invalidate(); }).catch((error) => {
          if (entry.active) {
            console.error("Could not watch Git metadata:", error);
            retire(key, entry);
          }
        }).finally(() => { if (!entry.active) void release(entry); });
      }
    };
    const listener = listen<GitMetadataChange>("git-metadata-changed", ({payload}) => {
      if (stopped) return;
      for (const root of payload.repositoryRoots) emitGitChanged(gitChangeForMetadata(root, payload));
      if (payload.metadataLinkChanged) {
        for (const [key, entry] of entries) {
          if (payload.repositoryRoots.some((root) => isGitChangeRelevant({repoPath: root}, entry.repoPath)))
            retire(key, entry);
        }
        reconcile();
      }
    });
    window.addEventListener("focus", reconcile);
    const unsubscribeRepositories = workspaceRuntimeRegistry.subscribeToStoreKey("git-repository", reconcile);
    const unsubscribeRoots = workspaceRuntimeRegistry.subscribeToStoreKey("file-system", reconcile);
    void listener.then(() => { listening = true; reconcile(); })
      .catch((error) => console.error("Could not receive Git metadata changes:", error));
    return () => {
      stopped = true;
      window.removeEventListener("focus", reconcile);
      unsubscribeRepositories(); unsubscribeRoots();
      void listener.then((unlisten) => unlisten()).catch(console.error);
      for (const [key, entry] of entries) retire(key, entry);
    };
  }, []);
  return null;
}
