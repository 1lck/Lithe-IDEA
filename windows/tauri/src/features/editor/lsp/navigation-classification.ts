import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { closestWorkspaceRoot } from "@/features/workspace/types/workspace-root";
import { invoke } from "@/platform/tauri-core";
import { detectLanguageFromPath } from "../utils/language-detection";

export type NavigationTargetClassification = "workspace" | "externalReadOnly" | "rejected";

export interface NavigationTargetDecision {
  classification: NavigationTargetClassification;
  isReadOnly: boolean;
}

/**
 * Asks Core (`lsp.classifyNavigationTarget`) whether a language-server jump may
 * open `path`. The host only supplies facts: the workspace root that contains
 * the file (or the primary root), and the language of the file and of the
 * document that started the jump. A Core failure rejects the jump.
 */
export async function classifyLspNavigationTarget(
  path: string,
  sourceFilePath: string,
): Promise<NavigationTargetDecision> {
  const state = useFileSystemStore.getStore(workspaceRuntimeRegistry.getActiveWorkspaceId()).getState();
  const roots = getNativeWorkspaceRootPaths(state.rootFolderPath, state.workspaceFolders);
  const workspaceRoot = closestWorkspaceRoot(path, roots) ?? state.rootFolderPath ?? undefined;
  try {
    return await invoke<NavigationTargetDecision>("lsp.classifyNavigationTarget", {
      platform: "windows",
      workspaceRoot,
      path,
      sourceLanguageID: detectLanguageFromPath(sourceFilePath),
      languageID: detectLanguageFromPath(path),
    });
  } catch {
    return { classification: "rejected", isReadOnly: true };
  }
}
