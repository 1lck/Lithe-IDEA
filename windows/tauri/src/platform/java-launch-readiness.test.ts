import { describe, expect, test } from "bun:test";
import {
  JAVA_BUILD_COMPILATION_ERRORS,
  JAVA_BUILD_FAILED,
  canOverrideJavaBuildVerdict,
  describeJavaLaunchBlock,
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

describe("describing a blocked Java launch", () => {
  test("offers an override and keeps Core's message", () => {
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, freshVerdict),
    );

    expect(block?.canOverride).toBe(true);
    expect(block?.message).toBe("The Java project has errors.");
    expect(block?.canRebuildIndex).toBe(false);
    expect(block?.markersMayBeStale).toBe(false);
    expect(block?.verdictNotScopedToTarget).toBe(false);
  });

  test("flags a verdict left behind by a failed builder", () => {
    // The RuoYi-Vue-Plus case: the builder crashed, then every later build
    // reported the markers it left without recompiling anything.
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, {
        ...freshVerdict,
        builderFailedEarlier: true,
        elapsedMilliseconds: 7,
        recovery: "rebuildJavaIndex",
      }),
    );

    expect(block?.markersMayBeStale).toBe(true);
    expect(block?.canRebuildIndex).toBe(true);
    expect(block?.canOverride).toBe(true);
  });

  test("flags a build that compiled nothing even without a recorded failure", () => {
    // A restarted language service loses the memory of the crash, but a
    // near-instant incremental build still cannot have produced the markers.
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, { ...freshVerdict, elapsedMilliseconds: 8 }),
    );

    expect(block?.markersMayBeStale).toBe(true);
  });

  test("does not call a real build's verdict stale", () => {
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, { ...freshVerdict, elapsedMilliseconds: 49982 }),
    );

    expect(block?.markersMayBeStale).toBe(false);
  });

  test("reports a verdict that an unrelated project could have decided", () => {
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, { ...freshVerdict, markerScope: "workspace" }),
    );

    expect(block?.verdictNotScopedToTarget).toBe(true);
  });

  test("a builder failure is never called stale, because it is the origin", () => {
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_FAILED, {
        ...freshVerdict,
        elapsedMilliseconds: 5012,
        recovery: "rebuildJavaIndex",
      }),
    );

    expect(block?.markersMayBeStale).toBe(false);
    expect(block?.canRebuildIndex).toBe(true);
    expect(block?.canOverride).toBe(true);
  });

  test("ignores a malformed report instead of trusting it", () => {
    const block = describeJavaLaunchBlock(
      buildFailure(JAVA_BUILD_COMPILATION_ERRORS, { markerScope: "elsewhere" }),
    );

    expect(block?.report).toBeUndefined();
    expect(block?.markersMayBeStale).toBe(false);
    expect(block?.canRebuildIndex).toBe(false);
    // The code alone still earns the override.
    expect(block?.canOverride).toBe(true);
  });

  test("returns null for failures that are not build verdicts", () => {
    expect(describeJavaLaunchBlock(buildFailure("javaToolchainMissing"))).toBeNull();
    expect(describeJavaLaunchBlock("cancelled")).toBeNull();
    expect(describeJavaLaunchBlock(null)).toBeNull();
  });
});
