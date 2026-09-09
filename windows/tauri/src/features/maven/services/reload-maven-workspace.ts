import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { normalizePath, stripTrailingPathSeparators } from "@/utils/path-helpers";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";
import type { MavenProject } from "../types/maven.types";
import { useMavenStore, type MavenReloadSnapshot } from "../stores/maven.store";

interface MavenReloadState {
  root: string | null;
  visiblePaths: string[];
  projectStatus: "idle" | "loading" | "ready" | "failed";
  projectError?: string | null;
  reloadRevision: number;
  projectReloadRevision: number;
  project: MavenProject | null;
  selectedProfiles?: string[];
  customProfiles?: string[];
  skipTests?: boolean;
  settingsPath?: string;
  localRepositoryPath?: string;
  mavenExecutablePath?: string;
  javaHomePath?: string;
  actions: {
    loadProject(root: string, visiblePaths?: string[]): Promise<void>;
    acknowledgeReload(revision?: number): void;
    restoreReloadSnapshot(
      snapshot: MavenReloadSnapshot,
      projectRevision: number,
      reloadRevision: number,
      message: string,
    ): void;
  };
}

interface FileSystemReloadState {
  rootFolderPath?: string;
  getAllProjectFiles(): Promise<FileEntry[]>;
}

interface JavaWorkspaceReloadOwner {
  stop(scope: WorkspaceLaunchScope): Promise<void>;
  prewarm(
    scope: WorkspaceLaunchScope,
    representativeJavaFile: string,
  ): Promise<{
    kind: "ready" | "cancelled" | "unavailable" | "failed" | "timedOut";
  }>;
}

export interface MavenWorkspaceReloadDependencies {
  hasWorkspace(workspaceId: string): boolean;
  getMavenState(workspaceId: string): MavenReloadState;
  getFileSystemState(workspaceId: string): FileSystemReloadState;
  getJavaOwner(): JavaWorkspaceReloadOwner;
}

export type MavenWorkspaceReloadOutcome = "completed" | "failed" | "noProject" | "stale";

const activeReloads = new Map<string, Promise<MavenWorkspaceReloadOutcome>>();
const JAVA_RELOAD_FAILED_MESSAGE = "Unable to reload the Java language server.";

function reloadKey(scope: WorkspaceLaunchScope): string {
  const root = normalizePath(stripTrailingPathSeparators(scope.root));
  const comparableRoot = /^(?:[A-Za-z]:\/|\/\/)/.test(root) ? root.toLowerCase() : root;
  return `${scope.workspaceId}\0${comparableRoot}`;
}

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
  reloadRevision?: number,
): Promise<MavenWorkspaceReloadOutcome> {
  let states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  const targetReloadRevision = reloadRevision ?? states.maven.reloadRevision;

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
  const preparation = javaFile ? await owner.prewarm(scope, javaFile) : null;

  states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  if (preparation && preparation.kind !== "ready") {
    throw new Error(JAVA_RELOAD_FAILED_MESSAGE);
  }
  states.maven.actions.acknowledgeReload(targetReloadRevision);
  return "completed";
}

async function performMavenWorkspaceReload(
  scope: WorkspaceLaunchScope,
  dependencies: MavenWorkspaceReloadDependencies,
): Promise<MavenWorkspaceReloadOutcome> {
  let states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  const reloadRevision = states.maven.reloadRevision;
  const projectReloadRevision = states.maven.projectReloadRevision;
  const previous: MavenReloadSnapshot = {
    projectStatus: states.maven.projectStatus,
    projectError: states.maven.projectError ?? null,
    project: states.maven.project,
    selectedProfiles: [...(states.maven.selectedProfiles ?? [])],
    customProfiles: [...(states.maven.customProfiles ?? [])],
    skipTests: states.maven.skipTests ?? false,
    settingsPath: states.maven.settingsPath ?? "",
    localRepositoryPath: states.maven.localRepositoryPath ?? "",
    mavenExecutablePath: states.maven.mavenExecutablePath ?? "",
    javaHomePath: states.maven.javaHomePath ?? "",
  };

  await states.maven.actions.loadProject(scope.root, [...states.maven.visiblePaths]);
  states = scopedStates(scope, dependencies);
  if (!states) return "stale";
  if (states.maven.projectStatus === "failed") return "failed";
  const hasProject = !!states.maven.project;

  try {
    const javaOutcome = await reloadJavaForMavenWorkspace(scope, dependencies, reloadRevision);
    return javaOutcome === "completed" && !hasProject ? "noProject" : javaOutcome;
  } catch (error) {
    states = scopedStates(scope, dependencies);
    if (states) {
      states.maven.actions.restoreReloadSnapshot(
        previous,
        projectReloadRevision,
        reloadRevision,
        error instanceof Error ? error.message : JAVA_RELOAD_FAILED_MESSAGE,
      );
    }
    throw error;
  }
}

export function reloadMavenWorkspaceProjects(
  scope: WorkspaceLaunchScope,
  dependencies: MavenWorkspaceReloadDependencies = defaultDependencies,
): Promise<MavenWorkspaceReloadOutcome> {
  const key = reloadKey(scope);
  const active = activeReloads.get(key);
  if (active) return active;

  const reload = performMavenWorkspaceReload(scope, dependencies).finally(() => {
    if (activeReloads.get(key) === reload) activeReloads.delete(key);
  });
  activeReloads.set(key, reload);
  return reload;
}
