import { inspectRunConfiguration } from "../api/run-core-api";
import { mapCoreToolchain } from "../utils/run-configuration";
import { joinPath, normalizePath } from "@/utils/path-helpers";
import { workspaceToolchainSelection } from "../utils/workspace-toolchain-paths";

/** Read the existing machine-local Run selection without probing a tool or
 * writing another build preference. The Java home mapping is the adapter for
 * the existing Java toolchain schema; generic runtime IDs remain opaque. */
export async function selectedBuildRuntimeExecutables(
  root: string,
  read = inspectRunConfiguration,
): Promise<Record<string, string>> {
  const snapshot = await read(root, false);
  const selected = workspaceToolchainSelection(root, mapCoreToolchain(snapshot.toolchain, snapshot.localToolchains));
  // Core keeps project-scoped selections relative to the workspace. Freeze the
  // same location Run/JDT consume before handing it to the native resolver,
  // whose executable inputs must be absolute. Native validation still owns
  // existence, JDK identity and rejection of malformed explicit paths.
  return {
    ...(selected.javaHomePath ? { java: normalizePath(joinPath(selected.javaHomePath, "bin/java.exe")) } : {}),
    ...selected.runtimeExecutablePaths,
  };
}
