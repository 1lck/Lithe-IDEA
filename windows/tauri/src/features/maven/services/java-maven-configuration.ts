import { invokeLsp } from "@/platform/lsp-core-adapter";
import type { MavenLaunchContext } from "../types/maven.types";

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

/**
 * Sends the workspace's Maven context to its running Java language session.
 *
 * JDT LS applies the change itself: new settings make it force-update every
 * Maven project, and `reloadProjects` re-resolves dependencies even when
 * nothing changed. Restarting the session instead would reuse its workspace
 * state and skip every project whose `pom.xml` did not change (#970).
 */
export function updateJavaMavenConfiguration(
  root: string,
  mavenContext: MavenLaunchContext,
  reloadProjects: boolean,
): Promise<JavaMavenConfigurationUpdate> {
  return invokeLsp<JavaMavenConfigurationUpdate>("lsp_update_maven_configuration", {
    workspacePath: root,
    mavenContext,
    reloadProjects,
  });
}
