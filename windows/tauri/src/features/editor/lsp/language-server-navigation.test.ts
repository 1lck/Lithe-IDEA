import { describe, expect, test } from "bun:test";
import { languageServerNavigationBlock } from "./language-server-navigation";

describe("language server jump messages", () => {
  test("does not warn when a session is already connected", () => {
    expect(
      languageServerNavigationBlock({
        availability: {
          phase: "ready",
          languageId: "java",
          workspacePath: "C:/work",
          feature: "supported",
        },
        fallbackStatus: "connected",
      }),
    ).toBeNull();
  });

  test("reports a negotiated unsupported capability", () => {
    expect(
      languageServerNavigationBlock({
        availability: {
          phase: "ready",
          languageId: "java",
          workspacePath: "C:/work",
          feature: "unsupported",
        },
        fallbackStatus: "connected",
      }),
    ).toEqual({ reason: "unsupported", languageId: "java" });
  });

  test("reports startup, failure, and not-ready states", () => {
    expect(
      languageServerNavigationBlock({
        availability: { phase: "unavailable", languageId: "java" },
        fallbackStatus: "connecting",
      }),
    ).toEqual({ reason: "preparing", languageId: "java" });
    expect(
      languageServerNavigationBlock({
        availability: { phase: "unavailable", languageId: "java" },
        fallbackStatus: "error",
      }),
    ).toEqual({ reason: "failed", languageId: "java" });
    expect(
      languageServerNavigationBlock({
        availability: { phase: "unavailable", languageId: "java" },
        fallbackStatus: "disconnected",
      }),
    ).toEqual({ reason: "notReady", languageId: "java" });
  });
});
