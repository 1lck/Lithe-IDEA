import { inspectRunConfiguration } from "../api/run-core-api";
import { mapCoreToolchain } from "../utils/run-configuration";
import { joinPath, normalizePath } from "@/utils/path-helpers";

/** Read the existing machine-local Run selection without probing a tool or
 * writing another build preference. The Java home mapping is the adapter for
 * the existing Java toolchain schema; generic runtime IDs remain opaque. */
export async function selectedBuildRuntimeExecutables(
  root: string,
  read = inspectRunConfiguration,
): Promise<Record<string, string>> {
  const snapshot = await read(root, false);
  const selected = mapCoreToolchain(snapshot.toolchain, snapshot.localToolchains);
  return {
    ...(selected.javaHomePath ? { java: normalizePath(joinPath(selected.javaHomePath, "bin/java.exe")) } : {}),
    ...selected.runtimeExecutablePaths,
  };
}
