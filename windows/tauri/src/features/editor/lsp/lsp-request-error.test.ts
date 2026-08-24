import { describe, expect, test } from "bun:test";
import {
  isCanceledLspRequest,
  isTransientJavaMarkerError,
  normalizeLspError,
} from "./lsp-request-error";

describe("LSP request error semantics", () => {
  test("preserves Core code and details from Error objects", () => {
    const error = Object.assign(new Error("Capability is pending"), {
      code: "not_supported",
      details: "codeLens",
    });

    expect(normalizeLspError(error)).toEqual({
      message: "Capability is pending",
      code: "not_supported",
      details: "codeLens",
    });
    expect(isTransientJavaMarkerError(error)).toBe(true);
  });

  test("does not retry unrelated unsupported capabilities", () => {
    const error = Object.assign(new Error("Capability is unavailable"), {
      code: "notSupported",
      details: "rename",
    });

    expect(isTransientJavaMarkerError(error)).toBe(false);
  });

  test("recognizes structured and server-originated cancellation", () => {
    expect(isCanceledLspRequest(Object.assign(new Error("Stopped"), { code: "cancelled" }))).toBe(
      true,
    );
    expect(isCanceledLspRequest(new Error("Request failed with -32801"))).toBe(true);
  });
});
