import { describe, expect, test } from "bun:test";
import { SERVICE_DEFAULTS } from "@/config/service-defaults";
import { getServiceUrls } from "@/config/services";

describe("service configuration", () => {
  test("keeps the website separate from retired cloud backend services", () => {
    expect(SERVICE_DEFAULTS.websiteBaseUrl).toBe("https://lithe.top");

    const serviceUrls = getServiceUrls();
    for (const retiredKey of [
      "apiBaseUrl",
      "telemetryDocsUrl",
      "pricingUrl",
      "dashboardUrl",
      "dashboardBillingUrl",
      "dashboardIntegrationsUrl",
      "dashboardCollaborationUrl",
    ]) {
      expect(retiredKey in serviceUrls).toBe(false);
    }

    expect(serviceUrls.docsUrl).toBe(`${serviceUrls.websiteBaseUrl}/docs`);
    expect(serviceUrls.extensionsCdnBaseUrl).toBe("");
    expect(serviceUrls.skillsRegistryUrl).toBe("");
    expect(serviceUrls.stableUpdateUrl).toBe(SERVICE_DEFAULTS.stableUpdateUrl);
    expect(serviceUrls.previewUpdateUrl).toBe(SERVICE_DEFAULTS.previewUpdateUrl);
  });
});
