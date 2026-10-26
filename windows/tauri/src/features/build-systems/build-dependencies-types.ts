import type { BuildModelReview } from "./build-systems-types";
import type { BuildRunDefinition } from "./build-run-types";
import type { BuildRunTerminal } from "./output/build-output-types";

/** Core's dependency node. Properties remain upstream data, never parsed here. */
export interface BuildDependencyNode {
  name: string;
  group?: string | null;
  version?: string | null;
  scope?: string | null;
  properties?: Record<string, string>;
  children: BuildDependencyNode[];
}
export interface BuildDependenciesReview extends BuildModelReview {
  projectId: string | null;
  kind: "dependencies";
  title: string;
}
export interface BuildDependenciesResult extends BuildDependenciesReview {
  terminal: BuildRunTerminal;
  dependencies: BuildDependencyNode[] | null;
  truncated?: boolean;
  dependencyTree?: {
    project: string;
    dependencies: BuildDependencyNode[];
    truncated: boolean;
  } | null;
}
export type BuildDependenciesDefinition = BuildRunDefinition;

/** Validate the bounded Core shape before making it renderable. No ecosystem
 * interpretation or output parsing takes place at this boundary. */
export function validDependencies(value: unknown): value is BuildDependencyNode[] {
  if (!Array.isArray(value)) return false;
  const pending: Array<{ rows: unknown[]; depth: number }> = [{ rows: value, depth: 0 }];
  let count = 0;
  while (pending.length) {
    const { rows, depth } = pending.pop()!;
    if (depth >= 64 && rows.length) return false;
    for (const row of rows) {
      if (++count > 10_000 || !row || typeof row !== "object") return false;
      const node = row as BuildDependencyNode;
      if (typeof node.name !== "string" || !Array.isArray(node.children)) return false;
      if (
        [node.group, node.version, node.scope].some(
          (field) => field != null && typeof field !== "string",
        )
      )
        return false;
      if (
        node.properties != null &&
        (typeof node.properties !== "object" ||
          Array.isArray(node.properties) ||
          Object.values(node.properties).some((field) => typeof field !== "string"))
      )
        return false;
      pending.push({ rows: node.children, depth: depth + 1 });
    }
  }
  return true;
}
