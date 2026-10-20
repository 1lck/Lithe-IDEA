import { afterAll, afterEach, describe, expect, spyOn, test } from "bun:test";
import * as runtime from "@/features/logging/frontend-log-runtime";
import { logger } from "./logger";

const forwarding = spyOn(runtime, "submitFrontendLog").mockResolvedValue(true);
afterAll(() => forwarding.mockRestore());
afterEach(() => {
  forwarding.mockClear();
  runtime.setFrontendDiagnosticEnabled(false);
  logger.configure({ enabled: true, minLevel: "warn" });
});

describe("installed editor logging", () => {
  test("forwards errors through the module log pipeline", () => {
    logger.error("LSPClient", "Language server failed", new Error("synthetic failure"));
    expect(forwarding).toHaveBeenCalledTimes(1);
    expect(forwarding.mock.calls[0]?.[0]).toMatchObject({
      level: "error",
      scope: "editor.LSPClient",
      message: "Language server failed",
    });
  });

  test("detailed records require the diagnostic switch", () => {
    logger.debug("Parser", "first");
    expect(forwarding).not.toHaveBeenCalled();
    runtime.setFrontendDiagnosticEnabled(true);
    logger.debug("Parser", "second");
    expect(forwarding).toHaveBeenCalledTimes(1);
  });
});
