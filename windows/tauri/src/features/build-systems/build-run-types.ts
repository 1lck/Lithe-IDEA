import type { BuildModelReview } from "./build-systems-types";

/** Common operation selection. Task/test fields mirror native serde; the
 * dependency adapter narrows its request to projectId before invoking. */
export interface BuildRunSelection {
  kind: "task" | "test" | "dependencies";
  taskId: string | null;
  projectId: string | null;
  targetId: string | null;
  modelTaskId: string | null;
  suite: string | null;
  case: string | null;
  userArguments: string[];
}
export interface BuildRunReview extends BuildModelReview {
  title: string;
  kind: "task" | "test" | "dependencies";
}
export type BuildRunScope = "workspace" | "project" | "target";
export interface BuildTaskDeclaration {
  id: string;
  displayName: string;
  execution?: "task" | "application" | "service";
  scopes?: BuildRunScope[];
  targetTags?: string[];
  fromModel?: boolean;
  requiresUserArguments?: boolean;
  category?: string[];
  group?: string;
}
export interface BuildRunDefinition {
  dependencies?: {
    source: "command" | "hostIntegration" | "provider";
    scopes?: ("workspace" | "project")[];
  } | null;
  tasks: BuildTaskDeclaration[];
  test?: { scopes: BuildRunScope[]; targetTags?: string[]; filters?: ("suite" | "case")[] } | null;
  /** Full Core-reviewed program declarations, never a guessed command/path. */
  programs: unknown[];
}
