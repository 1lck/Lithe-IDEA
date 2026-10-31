import { invokeLsp } from "@/platform/lsp-core-adapter";
import type { MavenLaunchContext } from "../types/maven.types";
import {
  prepareBuildLanguageImport,
  javaBuildImportSource,
} from "@/features/build-systems/build-language-import";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";

/** What the running Java language session did with a Maven configuration. */
export type JavaMavenConfigurationUpdate =
  | { kind: "noSession" }
  | {
      kind: "updated";
      /** JDT LS received new settings documents and re-imports on its own. */
      settingsChanged: boolean;
      /** Settings were unchanged, so a forced project update was requested. */
      projectsReloaded: boolean;
      /** Changed profiles are being applied. */
      profilesUpdating: boolean;
    };

export interface JavaMavenConfigurationDependencies {
  prepare: typeof prepareBuildLanguageImport;
  update: typeof invokeLsp;
}
const dependencies: JavaMavenConfigurationDependencies = {
  prepare: prepareBuildLanguageImport,
  update: invokeLsp,
};

/** Sends the exact current Maven context to JDT LS's existing re-import path.
 * A declared build import takes precedence over legacy settings. Reloading
 * projects still forces resolution when settings did not change (#970). */
export async function updateJavaMavenConfiguration(
  root: string,
  mavenContext: MavenLaunchContext | null,
  reloadProjects: boolean,
  scope: WorkspaceLaunchScope = {
    workspaceId: workspaceRuntimeRegistry.getActiveWorkspaceId(),
    root,
  },
  ports: JavaMavenConfigurationDependencies = dependencies,
): Promise<JavaMavenConfigurationUpdate> {
  if (!workspaceScopeMatchesRoot(scope, root)) throw new Error("plugin.build.staleContext");
  const prepared = await ports.prepare(scope, javaBuildImportSource(scope));
  try {
    const context = prepared.value.mavenContext ?? mavenContext;
    await prepared.validate();
    prepared.assertCurrent();
    if (!context) return { kind: "noSession" };
    // Only Maven's Core-shaped context has a hot update. Gradle is retained
    // by the running session and is read again on its next startup.
    return await ports.update<JavaMavenConfigurationUpdate>("lsp_update_maven_configuration", {
      workspacePath: root,
      mavenContext: context,
      reloadProjects,
    });
  } finally {
    prepared.dispose();
  }
}
