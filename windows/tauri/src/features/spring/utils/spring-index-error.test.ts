import { describe, expect, test } from "bun:test";
import {
  classifySpringIndexError,
  springIndexErrorTranslationKey,
  SpringIndexRequestError,
} from "./spring-index-error";

describe("classifySpringIndexError", () => {
  test("classifies unsupported roots before inspecting the request error", () => {
    const error = classifySpringIndexError(new Error("raw detail"), "wsl://Ubuntu/home/demo");
    expect(error.category).toBe("unsupportedRoot");
    expect(error.detail).toBe("raw detail");
  });

  test("maps stable Core error codes to user-facing categories", () => {
    expect(
      classifySpringIndexError(
        new SpringIndexRequestError("workspace_not_found", "missing"),
        "C:/work/demo",
      ).category,
    ).toBe("rootUnavailable");
    expect(
      classifySpringIndexError(
        new SpringIndexRequestError("permission_denied", "denied"),
        "C:/work/demo",
      ).category,
    ).toBe("permissionDenied");
    expect(
      classifySpringIndexError(
        new SpringIndexRequestError("timed_out", "slow"),
        "C:/work/demo",
      ).category,
    ).toBe("indexTimeout");
    expect(
      classifySpringIndexError(
        new SpringIndexRequestError("unknown", "failed"),
        "C:/work/demo",
      ).category,
    ).toBe("indexFailed");
  });

  test("keeps raw details out of the UI translation key", () => {
    const error = classifySpringIndexError(
      new SpringIndexRequestError("permission_denied", "C:/private/workspace"),
      "C:/private/workspace",
    );
    expect(springIndexErrorTranslationKey(error)).toBe(
      "springEndpoints.error.permissionDenied",
    );
    expect(springIndexErrorTranslationKey(error)).not.toContain("C:/private/workspace");
  });
});
