/** Reads the build evidence Rust Core attaches to a Java launch failure. */

/** Marker scope inferred from the build request sent upstream. */
export type JavaBuildMarkerScope = "launchTarget" | "workspace";

/** Recovery action Core indicates for an unsuccessful build. */
export type JavaBuildRecovery = "none" | "rebuildJavaIndex";

/** Evidence Core attaches to an unsuccessful Java launch build. */
export interface JavaBuildReport {
  markerScope: JavaBuildMarkerScope;
  builderFailedEarlier: boolean;
  elapsedMilliseconds: number;
  recovery: JavaBuildRecovery;
}

/** Structured failure codes that still leave a usable launch target possible. */
export const JAVA_BUILD_COMPILATION_ERRORS = "javaBuildCompilationErrors";
export const JAVA_BUILD_FAILED = "javaBuildFailed";

/**
 * The build reached a terminal failure, but existing output may still launch.
 *
 * `javaBuildCancelled` and request timeouts are deliberately absent: those
 * builds never reached a verdict, so retrying is the useful action and an
 * override would only launch against whatever happened to be on disk.
 */
const OVERRIDABLE_CODES = new Set([JAVA_BUILD_COMPILATION_ERRORS, JAVA_BUILD_FAILED]);

/** A terminal build failure returned while preparing a Java launch. */
export interface JavaBuildFailure {
  code: typeof JAVA_BUILD_COMPILATION_ERRORS | typeof JAVA_BUILD_FAILED;
  message: string;
  report?: JavaBuildReport;
}

function readReport(reason: unknown): JavaBuildReport | undefined {
  if (!reason || typeof reason !== "object") return undefined;
  const report = (reason as { javaBuildReport?: unknown }).javaBuildReport;
  if (!report || typeof report !== "object") return undefined;
  const candidate = report as Partial<JavaBuildReport>;
  if (
    (candidate.markerScope !== "launchTarget" && candidate.markerScope !== "workspace") ||
    typeof candidate.builderFailedEarlier !== "boolean" ||
    typeof candidate.elapsedMilliseconds !== "number" ||
    !Number.isFinite(candidate.elapsedMilliseconds) ||
    candidate.elapsedMilliseconds < 0 ||
    (candidate.recovery !== "none" && candidate.recovery !== "rebuildJavaIndex")
  ) {
    return undefined;
  }
  return candidate as JavaBuildReport;
}

/** Whether existing output may be launched after this terminal build failure. */
export function canOverrideJavaBuildVerdict(code: string | undefined): boolean {
  return code !== undefined && OVERRIDABLE_CODES.has(code);
}

/** Extracts a continuable build failure without trusting malformed evidence. */
export function readJavaBuildFailure(reason: unknown): JavaBuildFailure | null {
  if (!(reason instanceof Error)) return null;
  const coded = reason as Error & { code?: string };
  if (!canOverrideJavaBuildVerdict(coded.code)) return null;
  return {
    code: coded.code as JavaBuildFailure["code"],
    message: reason.message,
    report: readReport(reason),
  };
}
