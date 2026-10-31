import type { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import type { buildCore } from "@/platform/build-core-api";
import type { windowsBuildProviders } from "@/platform/build-provider-sessions";
import type { CoreBuildProviderTarget } from "@/platform/lsp-core-adapter";
import type { BuildConfigurationWatch, BuildConfigurationSourceVersion, BuildConfigurationCheck } from "./build-configuration-watch";

export interface BuildProject {
  id: string; name: string; path: string; parentID?: string;
  displayName?: string; properties: Record<string, string>;
}
export interface BuildDependencyNode {
  name: string; group?: string; version?: string; scope?: string;
  properties?: Record<string, string>; children?: BuildDependencyNode[];
}
export interface BuildDependencies {
  project: string; dependencies: BuildDependencyNode[]; truncated: boolean;
}
export interface BuildDependencySnapshot extends BuildDependencies { revision: string }

export interface BuildModel {
  projects: BuildProject[];
  targets: Array<{ id: string; projectID: string; name: string; path: string; tags: string[]; properties: Record<string, string> }>;
  tasks: Array<{ id: string; projectID: string; name: string; path: string; template: string;
    execution: "task" | "service"; properties: Record<string, string>; displayName?: string; description?: string; category?: string[]; group?: string }>;
  contentRoots: Array<{ projectID: string; path: string; kind: string }>;
  optionValues: Record<string, string[]>;
  truncated?: boolean;
}

export interface BuildToolContext {
  manifest: Record<string, unknown>;
  identity?: unknown;
  pluginDirectory: string;
  workspaceStateDirectory: string;
  tool: { executable: string };
  environment: Record<string, string>;
  executesProjectCode: boolean;
}

export interface BuildInstance {
  pluginID: string; buildSystemID: string; root: string;
  options: Record<string, unknown>;
}

export interface BuildOperation {
  id: string;
  instance: BuildInstance;
  phase: "preparing" | "running" | "succeeded" | "failed" | "cancelled";
  output: string;
  exitCode?: number;
  error?: string;
}

export interface BuildTestSelection {
  projectID?: string; targetID?: string; suite?: string; case?: string;
  selectorKind?: string; selectors?: string[]; userArguments?: string[];
}

export interface BuildNativeConfiguration {
  format: "litheBuildConfiguration";
  version: 1;
  sources: Array<{
    id: string; scope: "installation" | "user" | "workspace"; uri: string; revision: string; writable: boolean;
    rootElement: { name: string; namespace: string };
    fields: Array<{ id: string; kind: "text" | "file" | "directory" | "boolean" | "stringList";
      value: unknown; effectiveValue: unknown; effectiveSource: string; path: string[]; itemElement?: string }>;
  }>;
}

export interface BuildWork {
  record: BuildOperation;
  current: () => void;
  context: string;
  tool: BuildToolContext;
  signal: AbortSignal;
  native: <T>(task: Promise<T>) => Promise<T>;
  retainCleanup: (release: () => Promise<unknown>) => Promise<unknown>;
  perform: (command: string, request: Record<string, unknown>) => Promise<unknown>;
  decode: <R extends Record<string, unknown>>(command: string, request: Record<string, unknown>, includeContext?: boolean) => Promise<R>;
}

export interface WorkspacePorts {
  core: typeof buildCore;
  providers: Pick<typeof windowsBuildProviders, "send" | "stop">;
  tools: (target: CoreBuildProviderTarget, root: string, checkVersions: boolean) => Promise<BuildToolContext>;
  guard: typeof pluginPlanGuard;
  translate: (key: string) => string;
  configurationFiles?: {
    check?: (target: CoreBuildProviderTarget, sources: BuildConfigurationSourceVersion[]) => Promise<BuildConfigurationCheck>;
    prepare: (target: CoreBuildProviderTarget, root: string, operationID: string, snapshot: BuildNativeConfiguration, edits: BuildNativeConfigurationEdits) => Promise<boolean>;
    commit: (operationID: string) => Promise<void>;
    cancel: (operationID: string) => Promise<void>;
  };
  watchConfiguration?: (target: CoreBuildProviderTarget, sources: BuildConfigurationSourceVersion[], changed: () => void) => BuildConfigurationWatch;
}

export interface BuildNativeConfigurationEdits { sourceID: string; revision: string; values: Record<string, unknown> }
