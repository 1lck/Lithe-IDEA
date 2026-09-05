export type MavenProjectStatus = "idle" | "loading" | "ready" | "failed";
export type MavenTaskStatus = "idle" | "running" | "stopping" | "failed" | "cancelled";
export type MavenDependencyStatus = "idle" | "loading" | "ready" | "failed" | "cancelled";

export interface MavenProfile {
  id: string;
  isActiveByDefault: boolean;
}

export const MAVEN_SOURCE_ROOT_KINDS = [
  "mainJava",
  "mainResources",
  "testJava",
  "testResources",
  "generatedMain",
  "generatedTest",
] as const;

export type MavenSourceRootKind = (typeof MAVEN_SOURCE_ROOT_KINDS)[number];

export interface MavenSourceRoot {
  path: string;
  kind: MavenSourceRootKind;
}

export interface MavenModule {
  relativePath: string;
  groupId?: string | null;
  artifactId: string;
  version?: string | null;
  packaging: string;
  sourceRoots: MavenSourceRoot[];
  modules: MavenModule[];
}

export interface MavenProject {
  relativePath: string;
  groupId?: string | null;
  artifactId: string;
  version?: string | null;
  packaging: string;
  sourceRoots: MavenSourceRoot[];
  modules: MavenModule[];
  profiles: MavenProfile[];
  hasWrapper: boolean;
}

export interface MavenLaunchContext {
  version: 1;
  reactorPath: string;
  profiles: string[];
  settingsPath?: string | null;
  localRepositoryPath?: string | null;
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

export type MavenDependencyResolution = "resolved" | "omittedDuplicate" | "omittedConflict";

export interface MavenDependency {
  modulePath: string;
  groupId: string;
  artifactId: string;
  version: string;
  type: string;
  classifier?: string | null;
  scope: string;
  resolution: MavenDependencyResolution;
  selectedVersion?: string | null;
  children: MavenDependency[];
}

export interface MavenDependenciesResponse {
  modulePath: string;
  dependencies: MavenDependency[];
}

export interface MavenDependencyLoad {
  status: MavenDependencyStatus;
  dependencies: MavenDependency[];
  error: string | null;
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
  localRepositoryPath?: string | null;
  mavenExecutablePath?: string | null;
  javaHomePath?: string | null;
}

export interface MavenStoredConfiguration {
  portable?: MavenPortableConfiguration | null;
  local?: MavenLocalConfiguration | null;
}

export interface MavenSettings {
  settingsPath: string;
  localRepositoryPath: string;
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
