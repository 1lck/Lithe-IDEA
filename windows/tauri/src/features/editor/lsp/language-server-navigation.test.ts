import { describe, expect, test } from "bun:test";
import { languageServerUnavailableMessage } from "./language-server-navigation";

describe("language server jump messages", () => {
  test("does not warn when a session is already connected", () => {
    expect(
      languageServerUnavailableMessage({
        languageId: "java",
        status: "connected",
        hasSession: true,
      }),
    ).toBeNull();
  });

  test("reports startup, failure, and not-ready states", () => {
    expect(
      languageServerUnavailableMessage({
        languageId: "java",
        status: "connecting",
        hasSession: false,
      }),
    ).toBe("Java language server is starting.");
    expect(
      languageServerUnavailableMessage({
        languageId: "java",
        status: "error",
        lastError: "Could not find jdtls. Install Eclipse JDT Language Server and add it to PATH.",
        hasSession: false,
      }),
    ).toBe("Could not find jdtls. Install Eclipse JDT Language Server and add it to PATH.");
    expect(
      languageServerUnavailableMessage({
        languageId: "java",
        status: "disconnected",
        hasSession: false,
      }),
    ).toBe("Java language server is not ready.");
  });
});
