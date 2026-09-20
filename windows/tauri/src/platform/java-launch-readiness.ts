/**
 * Reading the evidence Rust Core attaches to a blocked Java launch.
 *
 * A build verdict from the Java language service is evidence, not a veto. The
 * Run panel has to explain why a launch was blocked, say whether the evidence
 * is still trustworthy, and leave the user a way forward. These helpers turn
 * Core's structured report into that decision without any of them deciding on
 * the user's behalf.
 */

/** Which projects' error markers decided the verdict. */
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

/** Structured failure codes Core returns for a Java launch build. */
export const JAVA_BUILD_COMPILATION_ERRORS = "javaBuildCompilationErrors";
export const JAVA_BUILD_FAILED = "javaBuildFailed";

/**
 * A build produced a verdict about the code, so the user may disagree with it.
 *
 * `javaBuildCancelled` and request timeouts are deliberately absent: those
 * builds never reached a verdict, so retrying is the useful action and an
 * override would only launch against whatever happened to be on disk.
 */
const OVERRIDABLE_CODES = new Set([JAVA_BUILD_COMPILATION_ERRORS, JAVA_BUILD_FAILED]);

/** Duration below which an incremental build cannot have compiled anything. */
const NO_COMPILATION_ELAPSED_MS = 50;

/** How the Run panel should present a blocked Java launch. */
export interface JavaLaunchBlock {
  /** Core's structured failure code, when it sent one. */
  code?: string;
  /** Core's user-facing message, shown as-is. */
  message: string;
  /** The evidence, when the failure came from a build. */
  report?: JavaBuildReport;
  /** The user may launch despite this verdict. */
  canOverride: boolean;
  /** Resetting the Java index is the indicated recovery. */
  canRebuildIndex: boolean;
  /** The verdict rests on markers that predate the current sources. */
  markersMayBeStale: boolean;
  /** The verdict could have been decided by an unrelated project. */
  verdictNotScopedToTarget: boolean;
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
    (candidate.recovery !== "none" && candidate.recovery !== "rebuildJavaIndex")
  ) {
    return undefined;
  }
  return candidate as JavaBuildReport;
}

/** Whether the user is allowed to launch despite this failure. */
export function canOverrideJavaBuildVerdict(code: string | undefined): boolean {
  return code !== undefined && OVERRIDABLE_CODES.has(code);
}

/**
 * Describes a blocked Java launch for the Run panel.
 *
 * Returns `null` for failures that are not build verdicts, such as a missing
 * JDK or an unusable classpath, which have their own handling.
 */
export function describeJavaLaunchBlock(reason: unknown): JavaLaunchBlock | null {
  if (!(reason instanceof Error)) return null;
  const coded = reason as Error & { code?: string };
  const report = readReport(reason);
  if (!canOverrideJavaBuildVerdict(coded.code) && !report) return null;

  const compiledNothing =
    report !== undefined && report.elapsedMilliseconds < NO_COMPILATION_ELAPSED_MS;
  return {
    code: coded.code,
    message: reason.message,
    report,
    canOverride: canOverrideJavaBuildVerdict(coded.code),
    canRebuildIndex: report?.recovery === "rebuildJavaIndex",
    // A builder failure leaves markers that later builds neither refresh nor
    // clear, and a build that compiled nothing cannot have produced them.
    markersMayBeStale:
      report !== undefined &&
      coded.code === JAVA_BUILD_COMPILATION_ERRORS &&
      (report.builderFailedEarlier || compiledNothing),
    verdictNotScopedToTarget: report?.markerScope === "workspace",
  };
}
