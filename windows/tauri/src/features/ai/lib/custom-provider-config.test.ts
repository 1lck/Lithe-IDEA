import { describe, expect, test } from "bun:test";
import {
  CUSTOM_AUTOCOMPLETE_PROVIDER_ID,
  CUSTOM_CHAT_PROVIDER_ID,
  resolveCustomProviderBaseUrl,
  resolveCustomProviderId,
  resolveCustomProviderModelId,
} from "@/features/ai/lib/custom-provider-config";
import type { Settings } from "@/features/settings/types/settings.types";

const settings = {
  aiCustomBaseUrl: "https://chat.example.test/v1",
  aiCustomModelId: "chat-model",
  aiAutocompleteCustomBaseUrl: "https://autocomplete.example.test/v1",
  aiAutocompleteCustomModelId: "autocomplete-model",
} as Settings;

describe("custom provider configuration", () => {
  test("keeps chat and autocomplete endpoints in separate scopes", () => {
    expect(resolveCustomProviderBaseUrl(settings, "chat")).toBe("https://chat.example.test/v1");
    expect(resolveCustomProviderBaseUrl(settings, "autocomplete")).toBe(
      "https://autocomplete.example.test/v1",
    );
  });

  test("keeps chat and autocomplete credential ids in separate scopes", () => {
    expect(resolveCustomProviderId("chat")).toBe(CUSTOM_CHAT_PROVIDER_ID);
    expect(resolveCustomProviderId("autocomplete")).toBe(CUSTOM_AUTOCOMPLETE_PROVIDER_ID);
  });

  test("resolves the configured model from the requested scope", () => {
    expect(resolveCustomProviderModelId(settings, "gpt-4o", "chat")).toBe("chat-model");
    expect(resolveCustomProviderModelId(settings, "gpt-4o", "autocomplete")).toBe(
      "autocomplete-model",
    );
  });
});
