/**
 * Helpers for the owning project that scopes a Java launch build.
 *
 * `vscode.java.buildWorkspace` always builds every Java project, but Java
 * Debug Server decides the build *succeeded* by looking at error markers on a
 * narrower set: the project that owns the main class, plus the projects on its
 * classpath. It finds that owner from the `projectName` Lithe sends, falling
 * back to resolving the main class name. When neither identifies exactly one
 * project, it evaluates markers across every project in the workspace instead,
 * and a launch can then be blocked by an error in a module the target does not
 * depend on.
 *
 * Nothing in that fallback is reported, so these helpers make Lithe's own half
 * of it explicit: whether an owning project was reported at all.
 */

/** Error code Rust Core returns when the build finished with error markers. */
export const JAVA_BUILD_COMPILATION_ERROR_CODE = "javaBuildCompilationErrors";

const UNSCOPED_BUILD_NOTE =
  "Lithe could not determine which project owns this main class, so the reported errors " +
  "may come from any project in the workspace rather than from this launch target.";

/**
 * Normalizes the owning project reported by `vscode.java.resolveMainClass`.
 *
 * An empty or whitespace-only name is treated as missing, because Java Debug
 * Server applies `isNotBlank` to it and would silently take the fallback path.
 * Returning `undefined` keeps that case distinguishable at the call site.
 */
export function resolveLaunchProjectName(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

/**
 * Returns the failure to surface for a launch build, adding the widened-scope
 * explanation when Lithe never identified the owning project.
 *
 * Every other failure, including a compilation-error failure that *was*
 * scoped, is returned untouched so the existing message stays intact.
 */
export function describeLaunchBuildFailure(
  reason: unknown,
  ownerProjectResolved: boolean,
): unknown {
  if (ownerProjectResolved || !(reason instanceof Error)) return reason;

  const coded = reason as Error & { code?: string; details?: string };
  if (coded.code !== JAVA_BUILD_COMPILATION_ERROR_CODE) return reason;

  const described = new Error(`${reason.message} ${UNSCOPED_BUILD_NOTE}`) as Error & {
    code?: string;
    details?: string;
  };
  described.code = coded.code;
  described.details = coded.details;
  return described;
}
