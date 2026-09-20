import { describe, expect, test } from "bun:test";
import {
  JAVA_BUILD_COMPILATION_ERROR_CODE,
  describeLaunchBuildFailure,
  resolveLaunchProjectName,
} from "./java-launch-build-scope";

function codedError(code: string, message = "The Java project has compilation errors.") {
  const error = new Error(message) as Error & { code?: string; details?: string };
  error.code = code;
  error.details = "module-a";
  return error;
}

describe("launch project name", () => {
  test("keeps a reported project name", () => {
    expect(resolveLaunchProjectName("ruoyi-admin")).toBe("ruoyi-admin");
  });

  test("treats a missing or blank name as unresolved", () => {
    // Java Debug Server applies `isNotBlank`, so an empty string silently takes
    // the same fallback path as a missing field.
    expect(resolveLaunchProjectName(undefined)).toBeUndefined();
    expect(resolveLaunchProjectName("")).toBeUndefined();
    expect(resolveLaunchProjectName("   ")).toBeUndefined();
    expect(resolveLaunchProjectName(42)).toBeUndefined();
  });
});

describe("launch build failure description", () => {
  test("explains the widened scope when no owning project was resolved", () => {
    const described = describeLaunchBuildFailure(
      codedError(JAVA_BUILD_COMPILATION_ERROR_CODE),
      false,
    ) as Error & { code?: string; details?: string };

    expect(described).toBeInstanceOf(Error);
    expect(described.message).toContain("The Java project has compilation errors.");
    expect(described.message).toContain("may come from any project in the workspace");
    // The structured failure contract must survive the rewrite.
    expect(described.code).toBe(JAVA_BUILD_COMPILATION_ERROR_CODE);
    expect(described.details).toBe("module-a");
  });

  test("leaves a scoped compilation failure untouched", () => {
    const reason = codedError(JAVA_BUILD_COMPILATION_ERROR_CODE);
    expect(describeLaunchBuildFailure(reason, true)).toBe(reason);
  });

  test("leaves other failure codes untouched even when unscoped", () => {
    // A timeout or builder crash says nothing about marker scope.
    const reason = codedError("javaBuildFailed");
    expect(describeLaunchBuildFailure(reason, false)).toBe(reason);
  });

  test("passes through a non-Error rejection", () => {
    expect(describeLaunchBuildFailure("cancelled", false)).toBe("cancelled");
  });
});
