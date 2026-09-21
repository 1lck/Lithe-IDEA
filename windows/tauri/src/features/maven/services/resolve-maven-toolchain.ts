import { resolveRunConfiguration } from "@/features/run/api/run-core-api";
import { discoverRunToolchains } from "@/features/run/api/run-host-api";

export interface MavenToolchainDependencies {
  resolveRunConfiguration: typeof resolveRunConfiguration;
  discoverRunToolchains: typeof discoverRunToolchains;
}

const defaultDependencies: MavenToolchainDependencies = {
  resolveRunConfiguration,
  discoverRunToolchains,
};

/**
 * Resolves the Maven installation this workspace runs, so project import and
 * the Maven command line agree on a single installation.
 *
 * JDT LS takes the local repository and mirrors from that installation's
 * `conf/settings.xml`. When the value stays empty the language server falls
 * back to its embedded defaults while Maven builds keep using the configured
 * installation, and the same project resolves against two different local
 * repositories.
 *
 * Each tier is consulted only when the previous one is empty, so a configured
 * workspace never pays for runtime probing.
 */
export async function resolveEffectiveMavenExecutable(
  root: string,
  configured: string,
  dependencies: MavenToolchainDependencies = defaultDependencies,
): Promise<string> {
  const explicit = configured.trim();
  if (explicit) return explicit;
  const fromRunToolchain = await runToolchainMaven(root, dependencies);
  if (fromRunToolchain) return fromRunToolchain;
  return await discoveredMaven(root, dependencies);
}

/** Reads the Maven selected in the Run configuration's machine toolchain. */
async function runToolchainMaven(
  root: string,
  dependencies: MavenToolchainDependencies,
): Promise<string> {
  try {
    const resolved = await dependencies.resolveRunConfiguration(root, []);
    return resolved.toolchain?.maven?.executablePath?.trim() ?? "";
  } catch {
    // A workspace without run documents still imports through Maven, so fall
    // through to discovery instead of failing the project load.
    return "";
  }
}

/**
 * Falls back to host discovery, which reports the project wrapper before any
 * machine installation. A wrapper resolves to no installation settings, which
 * matches what running the wrapper itself would read.
 */
async function discoveredMaven(
  root: string,
  dependencies: MavenToolchainDependencies,
): Promise<string> {
  try {
    const discovered = await dependencies.discoverRunToolchains(root);
    return discovered.maven[0]?.executablePath.trim() ?? "";
  } catch {
    return "";
  }
}
