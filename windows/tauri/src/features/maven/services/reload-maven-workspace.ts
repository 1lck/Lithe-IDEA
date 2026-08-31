import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";
import type { MavenProject } from "../types/maven.types";
import { useMavenStore } from "../stores/maven.store";

interface MavenReloadState {
  root: string | null;
  visiblePaths: string[];
  project: MavenProject | null;
  actions: {
    loadProject(root: string, visiblePaths?: string[]): Promise<void>;
    acknowledgeReload(): void;
  };
}

interface FileSystemReloadState {
  rootFolderPath?: string;
  getAllProjectFiles(): Promise<FileEntry[]>;
}

interface JavaWorkspaceReloadOwner {
  stop(scope: WorkspaceLaunchScope): Promise<void>;
  prewarm(scope: WorkspaceLaunchScope, representativeJavaFile: string): Promise<unknown>;
}

export interface MavenWorkspaceReloadDependencies {
  hasWorkspace(workspaceId: string): boolean;
  getMavenState(workspaceId: string): MavenReloadState;
  getFileSystemState(workspaceId: string): FileSystemReloadState;
  getJavaOwner(): JavaWorkspaceReloadOwner;
}

export type MavenWorkspaceReloadOutcome = "completed" | "noProject" | "stale";

const defaultDependencies: MavenWorkspaceReloadDependencies = {
  hasWorkspace: (workspaceId) => workspaceRuntimeRegistry.hasWorkspace(workspaceId),
  getMavenState: (workspaceId) => useMavenStore.getStore(workspaceId).getState(),
  getFileSystemState: (workspaceId) => useFileSystemStore.getStore(workspaceId).getState(),
  getJavaOwner: getJavaWorkspaceLanguageServerOwner,
};

function scopedStates(
  scope: WorkspaceLaunchScope,
  dependencies: MavenWorkspaceReloadDependencies,
): { maven: MavenReloadState; fileSystem: FileSystemReloadState } | null {
  if (!dependencies.hasWorkspace(scope.workspaceId)) return null;
  const maven = dependencies.getMavenState(scope.workspaceId);
  const fileSystem = dependencies.getFileSystemState(scope.workspaceId);
  return workspaceScopeMatchesRoot(scope, maven.root) &&
    workspaceScopeMatchesRoot(scope, fileSystem.rootFolderPath)
    ? { maven, fileSystem }
    : null;
}

export async function reloadJavaForMavenWorkspace(
  scope: WorkspaceLaunchScope,
  dependencies: MavenWorkspaceReloadDependencies = defaultDependencies,
): Promise<MavenWorkspaceReloadOutcome> {
  let states = scopedStates(scope, dependencies);
  if (!states) return "stale";

  const files = await states.fileSystem.getAllProjectFiles();
  states = scopedStates(scope, dependencies);
  if (!states) return "stale";

  const javaFile = files
    .filter((entry) => !entry.isDir && entry.path.toLowerCase().endsWith(".java"))
    .map((entry) => entry.path)
    .sort()[0];
  const owner = dependencies.getJavaOwner();
  await owner.stop(scope);

  states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  if (javaFile) await owner.prewarm(scope, javaFile);

  states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  states.maven.actions.acknowledgeReload();
  return "completed";
}

export async function reloadMavenWorkspaceProjects(
  scope: WorkspaceLaunchScope,
  dependencies: MavenWorkspaceReloadDependencies = defaultDependencies,
): Promise<MavenWorkspaceReloadOutcome> {
  let states = scopedStates(scope, dependencies);
  if (!states) return "stale";

  await states.maven.actions.loadProject(scope.root, [...states.maven.visiblePaths]);
  states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  if (!states.maven.project) return "noProject";

  return reloadJavaForMavenWorkspace(scope, dependencies);
}
