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
  name: string;
  tags?: string[];
}

export interface BuildModelTask {
  id: string;
  name: string;
  group?: string;
  category?: string[];
}

export interface BuildModelProject {
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
  model?: { projects?: BuildModelProject[]; truncated?: boolean } | null;
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
