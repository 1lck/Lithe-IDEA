import { inspectRunConfiguration, updateProjectToolchain } from "@/features/run/api/run-core-api";
import { discoverRunToolchains, writeRunDocuments } from "@/features/run/api/run-host-api";
import { mapCoreToolchain } from "@/features/run/utils/run-configuration";
import type { GlobalToolchain } from "@/features/run/types/run.types";

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
