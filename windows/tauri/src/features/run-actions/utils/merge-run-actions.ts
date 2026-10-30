import type { RunActionItem } from "../types/run-action.types";

function testIdentity(action: RunActionItem): string | undefined {
  const target: RunActionItem["testTarget"] =
    action.testTarget ??
    (action.declarativeTest && action.declarativeOwner
      ? {
          languageId: action.declarativeOwner.languageId,
          scope: action.declarativeTestScope ?? { kind: "workspace" as const },
        }
      : undefined);
  if (!target) return undefined;
  const scope = target.scope;
  // A language and path alone do not identify the test runner. In particular,
  // two accepted plugins may provide different frameworks for the same file.
  const runner = target.frameworkId
    ? ["framework", target.frameworkId]
    : [
        "owner",
        action.source,
        action.declarativeOwner?.pluginId ?? action.extensionId ?? action.id,
      ];
  return JSON.stringify([
    target.languageId,
    runner,
    scope.kind,
    "relativeFilePath" in scope ? scope.relativeFilePath : null,
    "identifier" in scope ? scope.identifier : null,
  ]);
}

/** Existing language/Worker and build-tool actions retain priority over a
 * contract action for the same explicit framework and scope. Opaque scripts and CodeLens
 * commands retain their owner; matching titles never prove equivalence. */
export function mergeRunActions(
  lspActions: RunActionItem[],
  projectActions: RunActionItem[],
  declarativeActions: RunActionItem[],
) {
  const ids = new Set<string>();
  const tests = new Set<string>();
  const filter = (actions: RunActionItem[]) =>
    actions.filter((action) => {
      const identity = testIdentity(action);
      if (ids.has(action.id) || (identity && tests.has(identity))) return false;
      ids.add(action.id);
      if (identity) tests.add(identity);
      return true;
    });
  return {
    lspActions: filter(lspActions),
    projectActions: filter(projectActions),
    declarativeActions: filter(declarativeActions),
  };
}
