import { executeCoreRuleSync } from "@/core/core-rules";
import type { HiddenPathRules } from "@/features/settings/lib/hidden-path-rules";
import { getRelativePath } from "@/utils/path-helpers";

/**
 * Hidden-path classification for the file tree, answered by Core's `workspace.classifyVisibility`
 * rule (rust/lithe-core-rules, run as wasm) so the tree hides exactly what search, snapshots and
 * local history hide. There is no TypeScript matcher and no default list here.
 *
 * Note: .agents/notes/implemented/architecture/2026-11-05-core-rules-wasm-sync-bridge.md
 */

interface ClassifyVisibilityResponse {
  hidden: boolean[];
}

/** A child entry of one directory: just what classification needs. */
export interface VisibilityChild {
  path: string;
  isDir: boolean;
}

/**
 * Classifies a batch of workspace-relative paths in one synchronous call. `isDirectory: null`
 * means the caller does not know the kind.
 */
export function classifyRelativePaths(
  rules: HiddenPathRules,
  entries: ReadonlyArray<{ path: string; isDirectory: boolean | null }>,
): boolean[] {
  if (entries.length === 0) return [];
  return executeCoreRuleSync<ClassifyVisibilityResponse>("workspace.classifyVisibility", {
    hiddenDirectoryNames: rules.hiddenDirectoryNames,
    hiddenFilePatterns: rules.hiddenFilePatterns,
    entries,
  }).hidden;
}

export interface DirectoryVisibilityClassifier {
  /**
   * Whether each child of `directoryPath` is hidden by the user's rules plus Core's built-ins.
   * One Core call covers all children that have no cached answer yet, never one call per file.
   */
  classifyChildren(directoryPath: string, children: readonly VisibilityChild[]): boolean[];
}

/**
 * Creates a classifier bound to one rule set. Answers are cached per directory for the lifetime
 * of the instance, so the owner makes a new instance whenever the rules change; that is the
 * rules version. `workspaceRootFor` maps a path to the workspace root it belongs to, or null/undefined
 * when the path is outside every root (nothing is hidden then).
 */
export function createDirectoryVisibilityClassifier(
  rules: HiddenPathRules,
  workspaceRootFor: (path: string) => string | null | undefined,
): DirectoryVisibilityClassifier {
  const cache = new Map<string, Map<string, boolean>>();

  return {
    classifyChildren(directoryPath, children) {
      let known = cache.get(directoryPath);
      if (!known) {
        known = new Map();
        cache.set(directoryPath, known);
      }
      const pending: Array<{ child: VisibilityChild; key: string; relative: string }> = [];
      const result = children.map((child) => {
        const key = child.isDir ? `${child.path}/` : child.path;
        const cached = known.get(key);
        if (cached !== undefined) return cached;
        const root = workspaceRootFor(child.path);
        const relative = root ? getRelativePath(child.path, root).replace(/\\/g, "/").trim() : "";
        // A workspace root itself, or a path outside every root, is never hidden.
        if (!relative) {
          known.set(key, false);
          return false;
        }
        pending.push({ child, key, relative });
        return null;
      });
      if (pending.length > 0) {
        const hidden = classifyRelativePaths(
          rules,
          pending.map(({ child, relative }) => ({ path: relative, isDirectory: child.isDir })),
        );
        pending.forEach(({ key }, index) => known.set(key, hidden[index] === true));
      }
      return children.map((child, index) => {
        if (result[index] !== null) return result[index] as boolean;
        return known.get(child.isDir ? `${child.path}/` : child.path) === true;
      });
    },
  };
}
