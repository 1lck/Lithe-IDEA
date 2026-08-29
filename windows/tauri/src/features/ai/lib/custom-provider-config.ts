import type { Settings } from "@/features/settings/types/settings.types";
import { getProviderApiToken } from "@/features/ai/services/ai-token-service";

export const CUSTOM_CHAT_PROVIDER_ID = "custom";
export const CUSTOM_AUTOCOMPLETE_PROVIDER_ID = "autocomplete-custom";

export type CustomProviderScope = "chat" | "autocomplete";

export function resolveCustomProviderId(scope: CustomProviderScope): string {
  return scope === "chat" ? CUSTOM_CHAT_PROVIDER_ID : CUSTOM_AUTOCOMPLETE_PROVIDER_ID;
}

export function resolveCustomProviderBaseUrl(
  settings: Settings,
  scope: CustomProviderScope,
): string {
  return scope === "chat" ? settings.aiCustomBaseUrl : settings.aiAutocompleteCustomBaseUrl;
}

export function resolveCustomProviderModelId(
  settings: Settings,
  modelId: string,
  scope: CustomProviderScope,
): string {
  const configuredModelId =
    scope === "chat"
      ? settings.aiCustomModelId.trim()
      : settings.aiAutocompleteCustomModelId.trim();
  const currentModelId = modelId.trim();

  return configuredModelId || currentModelId;
}

export async function getCustomProviderApiToken(
  scope: CustomProviderScope,
): Promise<string | null> {
  return getProviderApiToken(resolveCustomProviderId(scope));
}
