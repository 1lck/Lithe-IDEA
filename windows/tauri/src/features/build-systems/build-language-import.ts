import { invoke } from "@/platform/tauri-core";
import { getLspWorkspaceSessionSnapshot } from "@/platform/lsp-core-adapter";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import type { MavenLaunchContext } from "@/features/maven/types/maven.types";
import type { JavaLspGradle } from "@/features/editor/lsp/java-lsp-host-api";
import { getRelativePath } from "@/utils/path-helpers";
import { useBuildSystemsStore } from "./build-systems-store";
import { enqueueRegistryOperation, refreshBuildSystems } from "./build-systems-service";

// Core's language import intentionally omits execution-only skipTests/Java home.
export type MavenLanguageImportContext = Pick<
  MavenLaunchContext,
  "version" | "reactorPath" | "profiles"
> &
  Partial<MavenLaunchContext>;

export interface BuildLanguageImport {
  workspaceRoot: string;
  generation: number;
  identity: string;
  mavenContext: MavenLanguageImportContext | null;
  javaGradle: JavaLspGradle | null;
}

export interface PreparedBuildLanguageImport {
  value: BuildLanguageImport;
  assertCurrent: () => void;
  validate: () => Promise<void>;
  dispose: () => void;
}

interface ImportRequest {
  workspaceRoot: string;
  generation: number;
  sourcePath: string | null;
  expectedIdentity: string | null;
}

export interface BuildLanguageImportDependencies {
  refresh: typeof refreshBuildSystems;
  settle?: () => Promise<void>;
  read: (request: ImportRequest) => Promise<BuildLanguageImport>;
}
const dependencies: BuildLanguageImportDependencies = {
  refresh: refreshBuildSystems,
  settle: () => enqueueRegistryOperation(async () => {}),
  read: (request) =>
    enqueueRegistryOperation(() =>
      invoke<BuildLanguageImport>("declarative_plugins_build_language_import", { ...request }),
    ),
};

// Only the representative source identity is retained, never options or an
// import result. Each hot update resolves a fresh native snapshot for it.
const representatives = new WeakMap<
  WorkspaceRuntime,
  {
    scope: WorkspaceLaunchScope;
    sourcePath: string;
    hasMavenImport: boolean;
  }
>();

export function bindJavaBuildLanguageImport(
  scope: WorkspaceLaunchScope,
  filePath: string,
  hasMavenImport = false,
): void {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  // A running JDT session owns one representative reactor. Opening another
  // editor must not redirect subsequent hot updates to an unrelated reactor.
  if (activeJavaBuildImportSource(scope)) return;
  if (runtime)
    representatives.set(runtime, { scope: { ...scope }, sourcePath: filePath, hasMavenImport });
}

export function javaBuildImportSource(scope: WorkspaceLaunchScope): string | undefined {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  const bound = runtime && representatives.get(runtime);
  return bound && workspaceScopeMatchesRoot(scope, bound.scope.root) ? bound.sourcePath : undefined;
}

export function activeJavaBuildImportSource(scope: WorkspaceLaunchScope): string | undefined {
  const session = getLspWorkspaceSessionSnapshot({ workspacePath: scope.root, languageId: "java" });
  return session && !["failed", "stopped", "stopping"].includes(session.phase)
    ? javaBuildImportSource(scope)
    : undefined;
}

/** Passive preparation shared by editor attach, workspace prewarm and Maven
 * updates. A consumer owns the subscriptions until its final native check. */
export async function prepareBuildLanguageImport(
  scope: WorkspaceLaunchScope,
  filePath?: string,
  ports: BuildLanguageImportDependencies = dependencies,
): Promise<PreparedBuildLanguageImport> {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  const store = useBuildSystemsStore.getStore(scope.workspaceId);
  const standalone = !runtime?.descriptor.path;
  let stale = false;
  let disposed = false;
  const workspaceCurrent = () =>
    Boolean(
      runtime &&
      workspaceRuntimeRegistry.getWorkspace(scope.workspaceId) === runtime &&
      workspaceRuntimeRegistry.getActiveWorkspaceId() === scope.workspaceId &&
      (standalone
        ? !runtime.descriptor.path
        : workspaceScopeMatchesRoot(scope, runtime.descriptor.path)),
    );
  const assertWorkspace = () => {
    if (stale || disposed || !workspaceCurrent()) throw new Error("plugin.build.staleContext");
  };
  const releaseWorkspace = workspaceRuntimeRegistry.subscribe(() => {
    if (!workspaceCurrent()) stale = true;
  });
  let releaseStore = () => {};
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    releaseWorkspace();
    releaseStore();
  };
  try {
    assertWorkspace();
    // A loose file has no build-workspace registration. Preserve the existing
    // standalone Java/Maven path while still rejecting a project switch.
    if (standalone)
      return {
        value: {
          workspaceRoot: scope.root,
          generation: 0,
          identity: "standalone",
          mavenContext: null,
          javaGradle: null,
        },
        dispose,
        assertCurrent: assertWorkspace,
        validate: async () => {
          assertWorkspace();
        },
      };
    if (store.getState().status === "idle") await ports.refresh();
    else if (store.getState().status === "loading") await ports.settle?.();
    assertWorkspace();
    const snapshot = store.getState();
    if (
      snapshot.status !== "ready" ||
      snapshot.generation === null ||
      !workspaceScopeMatchesRoot(scope, snapshot.workspaceRoot)
    ) {
      throw new Error("plugin.build.staleContext");
    }
    const assertPlugins = pluginPlanGuard();
    const pluginIds = Object.values(snapshot.windows).map((window) => window.pluginId);
    const assertCurrent = () => {
      assertWorkspace();
      const state = store.getState();
      if (state !== snapshot) throw new Error("plugin.build.staleContext");
      for (const id of pluginIds) assertPlugins(id);
    };
    releaseStore = store.subscribe(() => {
      if (store.getState() !== snapshot) stale = true;
    });
    const request: ImportRequest = {
      workspaceRoot: snapshot.workspaceRoot!,
      generation: snapshot.generation,
      sourcePath: activeJavaBuildImportSource(scope) ?? filePath ?? null,
      expectedIdentity: null,
    };
    if (request.sourcePath) request.sourcePath = getRelativePath(request.sourcePath, scope.root);
    const value = await ports.read(request);
    assertCurrent();
    if (
      value.workspaceRoot !== request.workspaceRoot ||
      value.generation !== request.generation ||
      !value.identity
    ) {
      throw new Error("plugin.build.staleContext");
    }
    return {
      value,
      dispose,
      assertCurrent,
      validate: async () => {
        assertCurrent();
        const checked = await ports.read({ ...request, expectedIdentity: value.identity });
        assertCurrent();
        if (checked.identity !== value.identity) throw new Error("plugin.build.staleContext");
      },
    };
  } catch (error) {
    dispose();
    throw error;
  }
}

/** Called only after a successful native option edit. Gradle has no live
 * update path; the next launch reads its new offline/home options. */
export async function updateBuildLanguageImport(scope: WorkspaceLaunchScope): Promise<void> {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  if (!runtime || !representatives.get(runtime)?.hasMavenImport || !javaBuildImportSource(scope))
    return;
  const { updateJavaMavenConfiguration } =
    await import("@/features/maven/services/java-maven-configuration");
  await updateJavaMavenConfiguration(scope.root, null, false, scope);
}
