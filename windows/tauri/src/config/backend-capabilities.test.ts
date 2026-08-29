import { describe, expect, test } from "bun:test";
import { BACKEND_UNAVAILABLE_TOOLTIP, backendCapabilities } from "./backend-capabilities";
import { defaultSettings } from "@/features/settings/config/default-settings";

describe("default Windows workbench capability policy", () => {
  test("does not enable unavailable feature families by default", () => {
    expect(BACKEND_UNAVAILABLE_TOOLTIP).toBe("待开发");

    for (const capability of ["github", "remote", "docker", "agent"] as const) {
      expect(backendCapabilities[capability]).toBe(false);
    }

    expect(defaultSettings.coreFeatures.github).toBe(false);
    expect(defaultSettings.coreFeatures.remote).toBe(false);
    expect(defaultSettings.coreFeatures.docker).toBe(false);
    expect(defaultSettings.coreFeatures.aiChat).toBe(false);
    expect(backendCapabilities.run).toBe(true);
    expect(backendCapabilities.runActions).toBe(false);
  });
});
