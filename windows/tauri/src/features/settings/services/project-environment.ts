import { inspectRunConfiguration, updateProjectToolchain } from "@/features/run/api/run-core-api";
import { discoverRunToolchains, writeRunDocuments } from "@/features/run/api/run-host-api";
import { mapCoreToolchain } from "@/features/run/utils/run-configuration";
import type { GlobalToolchain } from "@/features/run/types/run.types";
import type { MavenSettings } from "@/features/maven/types/maven.types";

const defaultDependencies = {
  inspectRunConfiguration,
  updateProjectToolchain,
  discoverRunToolchains,
  writeRunDocuments,
};

// These operations never generate or edit a service configuration. Core owns
// document validation and preserves all existing per-service overrides.
export async function loadProjectEnvironment(root: string, dependencies = defaultDependencies) {
  const inspected = await dependencies.inspectRunConfiguration(root, false);
  const toolchain = mapCoreToolchain(inspected.toolchain, inspected.localToolchains);
  try {
    const discovered = await dependencies.discoverRunToolchains(root, toolchain);
    return { toolchain, discovered, discoveryError: null };
  } catch (error) {
    // A broken installation must remain editable instead of hiding its path.
    const discovered: Awaited<ReturnType<typeof discoverRunToolchains>> = {
      java: [],
      maven: [],
      runtimes: [],
    };
    return { toolchain, discovered, discoveryError: String(error) };
  }
}

export async function saveProjectEnvironment(
  root: string,
  toolchain: GlobalToolchain,
  dependencies = defaultDependencies,
) {
  const mutation = await dependencies.updateProjectToolchain(root, toolchain);
  await dependencies.writeRunDocuments(root, [
    { relativePath: "run/local.json", contents: mutation.document },
  ]);
}

interface MavenSettingsTarget {
  getState(): {
    root: string | null;
    actions: { saveLocalConfiguration(settings: MavenSettings): Promise<void> };
  };
}

interface RunProjectTarget {
  getState(): {
    root: string | null;
    status: string;
    invalidMessage?: string;
    actions: { loadProject(root: string): Promise<void> };
  };
}

/** A save failure, recording whether the project defaults already reached disk. */
export class ProjectEnvironmentSaveError extends Error {
  constructor(
    readonly defaultsWritten: boolean,
    readonly cause: unknown,
  ) {
    super(String(cause));
  }
}

/**
 * Writes the project defaults and the Maven local settings, then starts
 * refreshing Run's view of the project.
 *
 * The save is complete once both documents are written. The Run refresh may
 * wait for an in-flight identification, so it is returned rather than awaited:
 * `runRefresh` resolves to the reload failure, or `null` when Run is current or
 * belongs to another project.
 */
export async function saveProjectEnvironmentSettings(
  root: string,
  toolchain: GlobalToolchain,
  targets: {
    maven: { settings: MavenSettings; store: MavenSettingsTarget } | null;
    run: RunProjectTarget;
  },
  dependencies = defaultDependencies,
): Promise<{ runRefresh: Promise<string | null> }> {
  let defaultsWritten = false;
  try {
    await saveProjectEnvironment(root, toolchain, dependencies);
    defaultsWritten = true;
    if (targets.maven && targets.maven.store.getState().root === root) {
      await targets.maven.store.getState().actions.saveLocalConfiguration({
        ...targets.maven.settings,
        mavenExecutablePath: toolchain.mavenExecutablePath,
        javaHomePath: toolchain.mavenJavaHomePath,
      });
    }
  } catch (cause) {
    throw new ProjectEnvironmentSaveError(defaultsWritten, cause);
  }
  return { runRefresh: refreshRunProject(root, targets.run) };
}

async function refreshRunProject(root: string, run: RunProjectTarget): Promise<string | null> {
  if (run.getState().root !== root) return null;
  try {
    await run.getState().actions.loadProject(root);
  } catch (cause) {
    return String(cause);
  }
  const state = run.getState();
  return state.root === root && state.status === "invalid" ? (state.invalidMessage ?? "") : null;
}
