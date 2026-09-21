import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { invokeLsp, type JavaEntrypoints } from "@/platform/lsp-core-adapter";
import { normalizePath, joinPath } from "@/utils/path-helpers";
import {
  getProjectPreparation,
  projectPreparationStore,
  type PreparationEntry,
} from "../stores/project-preparation.store";

// Note: 入口点归属见 .agents/notes/proposed/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md

/** Outcome of asking the Java language service which classes can be launched. */
export type JavaEntrypointDiscovery =
  | { kind: "discovered"; entrypoints: JavaEntrypoints }
  /** The Java service is starting or still importing the project. */
  | { kind: "pending" }
  | { kind: "failed"; message: string };

function preparationSettled(entry: PreparationEntry | undefined): boolean {
  return Boolean(entry && !entry.blocksRun);
}

function preparationFailed(entry: PreparationEntry | undefined): boolean {
  return Boolean(entry && entry.status === "failed" && entry.blocksRun);
}

function failureMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) return error.message;
  return "The Java language service could not list runnable classes.";
}

/**
 * Asks JDT for launchable classes once it finished preparing the project.
 *
 * Asking earlier would return a partial list mid-import, so an unprepared
 * workspace reports `pending` and the caller keeps its previous list. The
 * Java service is started here when nothing started it yet, through the same
 * workspace owner the launch path uses.
 */
export async function discoverJavaEntrypoints(
  scope: WorkspaceLaunchScope,
  javaSources: string[],
): Promise<JavaEntrypointDiscovery> {
  const preparation = getProjectPreparation(scope.root);
  if (preparationFailed(preparation)) {
    return { kind: "failed", message: "The Java language service failed to prepare the project." };
  }
  if (!preparationSettled(preparation)) {
    if (!preparation && javaSources.length > 0) {
      void getJavaWorkspaceLanguageServerOwner().prewarm(
        scope,
        normalizePath(joinPath(scope.root, javaSources[0])),
      );
    }
    return { kind: "pending" };
  }
  try {
    return {
      kind: "discovered",
      entrypoints: await invokeLsp<JavaEntrypoints>("java_entrypoints", {
        workspacePath: scope.root,
      }),
    };
  } catch (error) {
    return { kind: "failed", message: failureMessage(error) };
  }
}

/**
 * Calls `listener` once the Java service finished or failed preparing
 * `root`, and returns a function that stops waiting.
 */
export function whenJavaProjectPrepared(root: string, listener: () => void): () => void {
  let done = false;
  const check = () => {
    const entry = getProjectPreparation(root);
    if (done || !(preparationSettled(entry) || preparationFailed(entry))) return;
    done = true;
    unsubscribe();
    listener();
  };
  const unsubscribe = projectPreparationStore.subscribe(check);
  queueMicrotask(check);
  return () => {
    done = true;
    unsubscribe();
  };
}
