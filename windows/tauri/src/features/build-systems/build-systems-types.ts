/**
 * Shapes returned by the Rust build registry (`plugin_host/build.rs`). The
 * frontend only renders this state; every build semantic is computed by Core
 * through the registry, so no ecosystem knowledge lives here.
 */

export interface BuildOptionChoice {
  value: string;
  title?: string;
  fromModel?: boolean;
}

export interface BuildOptionDescription {
  id: string;
  displayName?: string;
  kind: "boolean" | "singleSelect" | "multiSelect" | "text" | "file" | "directory";
  value: unknown;
  choices: BuildOptionChoice[];
  allowCustom?: boolean;
}

export interface BuildModelTarget {
  id?: string;
  projectID?: string;
  path?: string;
  name: string;
  tags?: string[];
}

export interface BuildModelTask {
  id: string;
  name: string;
  group?: string;
  category?: string[];
  projectID?: string;
  template?: string;
  execution?: "task" | "application" | "service";
  displayName?: string;
}

export interface BuildModelProject {
  id?: string;
  displayName?: string;
  name: string;
  path: string;
  properties?: Record<string, unknown>;
  targets?: BuildModelTarget[];
  tasks?: BuildModelTask[];
}

export interface BuildModelError {
  code: string;
  message: string;
}

/** One detected build-system instance with its session state. */
export interface BuildInstanceView {
  pluginID: string;
  buildSystemID: string;
  displayName: string;
  root: string;
  markers: string[];
  modelSource: "static" | "command" | "hostIntegration" | "provider" | null;
  model?: {
    projects?: BuildModelProject[];
    targets?: BuildModelTarget[];
    tasks?: BuildModelTask[];
    truncated?: boolean;
  } | null;
  modelError?: BuildModelError | null;
  stale: boolean;
  syncDigest: string | null;
  optionFingerprint: string | null;
  options: BuildOptionDescription[];
}

export interface BuildIssue {
  kind: "rejected" | "shadowed";
  pluginID?: string;
  buildSystemID?: string;
  by?: string;
  index?: number;
  error?: { code: string; message: string };
}

export interface BuildView {
  generation: number;
  workspaceRoot: string;
  instances: BuildInstanceView[];
  issues: BuildIssue[];
}

/** A single-use native review, bound to the calling window and generation. */
export interface BuildModelReview {
  operationId: string;
  pluginId: string;
  buildSystemId: string;
  workspaceRoot: string;
  root: string;
  generation: number;
  executesProjectCode: boolean;
  mayUseNetwork: boolean;
  provider?: BuildProviderReview;
}

export interface BuildProviderReview {
  token: number;
  context: {
    window: string;
    workspaceRoot: string;
    launchWorkspaceRoot?: string;
    generation: number;
    pluginId: string;
    packageIdentity: string;
    buildSystem: string;
    instanceRoot: string;
    instanceDirectory: string;
  };
  executesProjectCode: boolean;
  mayUseNetwork: boolean;
  launchPlan: Record<string, unknown>;
  invocationPlan?: Record<string, unknown>;
  program: {
    pluginId: string;
    languageId: string;
    serverPath: string;
    serverArgs: string[];
    environment: Record<string, string>;
    initializationOptions?: unknown;
    workspaceConfiguration?: unknown;
  };
}

/** Refuse incomplete or foreign native reviews before asking for consent. */
function normalizedProviderWorkspace(value: string): string {
  return value
    .replace(/\\/g, "/")
    .replace(/^\/\/\?\/UNC\//i, "//")
    .replace(/^\/\/\?\//, "")
    .replace(/\/$/, "")
    .toLowerCase();
}
export function validBuildProviderReview(review: BuildModelReview): boolean {
  const provider = review.provider;
  if (provider === undefined) return true;
  return (
    !!provider &&
    Number.isSafeInteger(provider.token) &&
    provider.token > 0 &&
    provider.context?.pluginId === review.pluginId &&
    provider.context.buildSystem === review.buildSystemId &&
    typeof provider.context.workspaceRoot === "string" &&
    normalizedProviderWorkspace(provider.context.workspaceRoot) ===
      normalizedProviderWorkspace(review.workspaceRoot) &&
    provider.context.generation === review.generation &&
    provider.context.instanceRoot === review.root &&
    typeof provider.context.packageIdentity === "string" &&
    provider.context.packageIdentity.length > 0 &&
    typeof provider.program?.serverPath === "string" &&
    provider.program.serverPath.length > 0 &&
    provider.program.pluginId === review.pluginId &&
    Array.isArray(provider.program.serverArgs) &&
    provider.program.serverArgs.every((arg) => typeof arg === "string") &&
    !!provider.launchPlan &&
    typeof provider.launchPlan === "object" &&
    !!provider.program.environment &&
    typeof provider.program.environment === "object" &&
    typeof provider.executesProjectCode === "boolean" &&
    typeof provider.mayUseNetwork === "boolean" &&
    (!provider.executesProjectCode || review.executesProjectCode) &&
    (!provider.mayUseNetwork || review.mayUseNetwork)
  );
}

export interface BuildModelLoadResult {
  operationId: string;
  view: BuildView;
  stderr: string;
}

/** Declared build system of one enabled plugin, for window registration. */
export interface BuildCatalogEntry {
  pluginId: string;
  pluginDisplayName: string;
  buildSystemId: string;
  buildSystemDisplayName: string;
  icon: string | null;
}

/** Instances of one build system, as one tool window shows them. */
export interface BuildWindowState {
  pluginId: string;
  buildSystemId: string;
  displayName: string;
  instances: BuildInstanceView[];
  selectedRoot: string | null;
}
