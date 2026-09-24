import { describe, expect, test } from "bun:test";
import {
  JAVA_BUILD_COMPILATION_ERRORS,
  JAVA_BUILD_FAILED,
  canOverrideJavaBuildVerdict,
  readJavaBuildFailure,
  type JavaBuildReport,
} from "./java-launch-readiness";

const freshVerdict: JavaBuildReport = {
  markerScope: "launchTarget",
  builderFailedEarlier: false,
  elapsedMilliseconds: 12511,
  recovery: "none",
};

function buildFailure(code: string, report?: unknown, message = "The Java project has errors.") {
  const error = new Error(message) as Error & { code?: string; javaBuildReport?: unknown };
  error.code = code;
  error.javaBuildReport = report;
  return error;
}

describe("overridable build verdicts", () => {
  test("a verdict about the code may be overridden", () => {
    expect(canOverrideJavaBuildVerdict(JAVA_BUILD_COMPILATION_ERRORS)).toBe(true);
    expect(canOverrideJavaBuildVerdict(JAVA_BUILD_FAILED)).toBe(true);
  });

  test("a build that never reached a verdict may not", () => {
    // Retrying is the useful action; overriding would launch against whatever
    // happens to be on disk.
    expect(canOverrideJavaBuildVerdict("javaBuildCancelled")).toBe(false);
    expect(canOverrideJavaBuildVerdict("requestTimeout")).toBe(false);
    expect(canOverrideJavaBuildVerdict(undefined)).toBe(false);
  });
});

describe("reading a Java build failure", () => {
  test("keeps Core's code, message, and evidence", () => {
    const failure = readJavaBuildFailure(buildFailure(JAVA_BUILD_COMPILATION_ERRORS, freshVerdict));

    expect(failure).toEqual({
      code: JAVA_BUILD_COMPILATION_ERRORS,
      message: "The Java project has errors.",
      report: freshVerdict,
    });
  });

  test("preserves evidence without turning elapsed time into a verdict", () => {
    const failure = readJavaBuildFailure(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, {
        ...freshVerdict,
        builderFailedEarlier: true,
        elapsedMilliseconds: 7,
        recovery: "rebuildJavaIndex",
      }),
    );

    expect(failure?.report).toEqual({
      ...freshVerdict,
      builderFailedEarlier: true,
      elapsedMilliseconds: 7,
      recovery: "rebuildJavaIndex",
    });
  });

  test("ignores a malformed report instead of trusting it", () => {
    const failure = readJavaBuildFailure(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, { markerScope: "elsewhere" }),
    );

    expect(failure?.report).toBeUndefined();
  });

  test("rejects non-finite and negative elapsed evidence", () => {
    expect(
      readJavaBuildFailure(
        buildFailure(JAVA_BUILD_FAILED, {
          ...freshVerdict,
          elapsedMilliseconds: Number.NaN,
        }),
      )?.report,
    ).toBeUndefined();
    expect(
      readJavaBuildFailure(
        buildFailure(JAVA_BUILD_FAILED, {
          ...freshVerdict,
          elapsedMilliseconds: -1,
        }),
      )?.report,
    ).toBeUndefined();
  });

  test("returns null for failures that are not build verdicts", () => {
    expect(readJavaBuildFailure(buildFailure("javaToolchainMissing"))).toBeNull();
    expect(readJavaBuildFailure("cancelled")).toBeNull();
    expect(readJavaBuildFailure(null)).toBeNull();
  });
});
