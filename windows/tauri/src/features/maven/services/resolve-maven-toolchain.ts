import { resolveRunConfiguration } from "@/features/run/api/run-core-api";
import { resolveMavenInstallation } from "../api/maven-host-api";

export interface MavenToolchainDependencies {
  resolveRunConfiguration: typeof resolveRunConfiguration;
  resolveMavenInstallation: typeof resolveMavenInstallation;
}

const defaultDependencies: MavenToolchainDependencies = {
  resolveRunConfiguration,
  resolveMavenInstallation,
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
 * Neither tier launches a process. This runs inside the Maven project load that
 * the Java editor path awaits before starting the language server, so a
 * `mvn -version` probe here would delay every first Java file open, and a cold
 * wrapper would block it for as long as the wrapper takes to download Maven.
 */
export async function resolveEffectiveMavenExecutable(
  root: string,
  configured: string,
  dependencies: MavenToolchainDependencies = defaultDependencies,
): Promise<string> {
  const explicit = configured.trim();
  if (explicit) return explicit;
  const fromRunToolchain = await runToolchainMaven(root, dependencies);
  return await installedMaven(root, fromRunToolchain, dependencies);
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
    // through to host resolution instead of failing the project load.
    return "";
  }
}

/**
 * Applies the host's build-time candidate order to whatever the Run
 * configuration selected. A project wrapper wins over a machine installation,
 * matching what a build would run, and resolves to no installation settings
 * because it sits outside an installation.
 */
async function installedMaven(
  root: string,
  overridePath: string,
  dependencies: MavenToolchainDependencies,
): Promise<string> {
  try {
    const resolved = await dependencies.resolveMavenInstallation(
      root,
      overridePath || undefined,
    );
    return resolved?.trim() ?? "";
  } catch {
    return overridePath;
  }
}
