import { describe, expect, test } from "bun:test";
import {
  LANGUAGE_SERVER_FAILURE_COOLDOWN_MS,
  clearLanguageServerFailure,
  isLanguageServerFailureCoolingDown,
  recordLanguageServerFailure,
} from "./language-server-failure-cooldown";

describe("language server failure cooldown", () => {
  test("blocks automatic retries during the cooldown window", () => {
    const failures = new Map<string, number>();
    const serverKey = "C:/project:java";
    recordLanguageServerFailure(failures, serverKey, 1_000);

    expect(
      isLanguageServerFailureCoolingDown(failures, serverKey, 1_000 + LANGUAGE_SERVER_FAILURE_COOLDOWN_MS - 1),
    ).toBe(true);
    expect(failures.has(serverKey)).toBe(true);
  });

  test("allows automatic retries after the cooldown expires", () => {
    const failures = new Map<string, number>();
    const serverKey = "C:/project:java";
    recordLanguageServerFailure(failures, serverKey, 1_000);

    expect(
      isLanguageServerFailureCoolingDown(failures, serverKey, 1_000 + LANGUAGE_SERVER_FAILURE_COOLDOWN_MS),
    ).toBe(false);
    expect(failures.has(serverKey)).toBe(false);
  });

  test("manual clear removes the failure so retries start immediately", () => {
    const failures = new Map<string, number>();
    const serverKey = "C:/project:java";
    recordLanguageServerFailure(failures, serverKey, 1_000);
    clearLanguageServerFailure(failures, serverKey);

    expect(isLanguageServerFailureCoolingDown(failures, serverKey, 1_001)).toBe(false);
  });
});
