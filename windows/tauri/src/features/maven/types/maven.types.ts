export type MavenProjectStatus = "idle" | "loading" | "ready" | "failed";
export type MavenTaskStatus = "idle" | "running" | "stopping" | "failed";

export interface MavenProfile {
  id: string;
  isActiveByDefault: boolean;
}

export interface MavenModule {
  relativePath: string;
  groupId?: string | null;
  artifactId: string;
  version?: string | null;
  packaging: string;
  modules: MavenModule[];
}

export interface MavenProject {
  relativePath: string;
  groupId?: string | null;
  artifactId: string;
  version?: string | null;
  packaging: string;
  modules: MavenModule[];
  profiles: MavenProfile[];
  hasWrapper: boolean;
}

export interface MavenLaunchContext {
  version: 1;
  reactorPath: string;
  profiles: string[];
  settingsPath?: string | null;
  skipTests: boolean;
  mavenExecutablePath?: string | null;
  javaHomePath?: string | null;
}

export interface MavenLaunchPlan {
  version: 1;
  executable: { toolchain: "project-maven" };
  arguments: string[];
  workingDirectory: string;
  configurationFingerprint: string;
}

export interface MavenDiagnostic {
  path: string;
  line: number;
  column?: number | null;
  severity: "error" | "warning";
  message: string;
}

export interface MavenPortableConfiguration {
  version: 1;
  selectedProfiles: string[];
  customProfiles: string[];
  skipTests: boolean;
}

export interface MavenLocalConfiguration {
  version: 1;
  settingsPath?: string | null;
  mavenExecutablePath?: string | null;
  javaHomePath?: string | null;
}

export interface MavenStoredConfiguration {
  portable?: MavenPortableConfiguration | null;
  local?: MavenLocalConfiguration | null;
}

export interface MavenSettings {
  settingsPath: string;
  mavenExecutablePath: string;
  javaHomePath: string;
}

export const MAVEN_LIFECYCLE_PHASES = [
  "clean",
  "validate",
  "compile",
  "test",
  "package",
  "verify",
  "install",
  "site",
  "deploy",
] as const;

export type MavenLifecyclePhase = (typeof MAVEN_LIFECYCLE_PHASES)[number];
