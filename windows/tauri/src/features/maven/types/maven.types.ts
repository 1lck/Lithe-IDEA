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

export interface MavenTestFailureDetail {
  name: string;
  kind: "failure" | "error";
  message?: string | null;
  path?: string | null;
  line?: number | null;
  column?: number | null;
}

/** One method's outcome read from the run's Surefire/Failsafe XML reports. */
export interface MavenTestCase {
  /** Binary class name, such as `demo.OrderTest$Refunds`. */
  className: string;
  method: string;
  status: "passed" | "failed" | "error" | "skipped";
  message?: string | null;
  invocations: number;
}

export interface MavenTestResults {
  testsRun: number;
  failures: number;
  errors: number;
  skipped: number;
  passed: number;
  success: boolean;
  failureDetails: MavenTestFailureDetail[];
  /** Per-method outcomes; empty when the run wrote no readable reports. */
  testCases?: MavenTestCase[];
}

/** Which XML reports belong to a finished test run. */
export interface MavenTestReportsRequest {
  /** Workspace-relative module directory; `null` for the workspace root. */
  module: string | null;
  classes: string[];
  notBeforeMillis: number;
}

export interface JavaTestMethod {
  name: string;
  line: number;
  endLine: number;
}

export interface MavenTestRun {
  module: string | null;
  selector: string;
  title: string;
  /** Binary name of the selected test class; its reports carry the outcomes. */
  className?: string;
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

export type MavenEffectiveConfigurationStatus = "idle" | "loading" | "ready" | "failed";

/**
 * What a Maven launch would use for the current settings, plus the values
 * machine detection found while ignoring saved overrides. A `null` field means
 * detection found nothing, not that the field is disabled.
 */
export interface MavenEffectiveConfiguration {
  settingsPath: string | null;
  localRepositoryPath: string | null;
  mavenExecutablePath: string | null;
  javaHomePath: string | null;
  detectedSettingsPath: string | null;
  detectedLocalRepositoryPath: string | null;
  detectedMavenExecutablePath: string | null;
  detectedJavaHomePath: string | null;
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
