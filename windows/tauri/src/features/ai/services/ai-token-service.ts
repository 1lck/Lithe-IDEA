import { invoke } from "@/platform/tauri-core";

/**
 * Token management utilities for AI providers
 * Persists provider API tokens through the platform secure store
 * (OS keychain on macOS, Windows Credential Manager via keyring).
 */

const TOKEN_KEY_PREFIX = "ai-provider-token/";

function tokenKey(providerId: string): string {
  const normalized = providerId.trim();
  if (!normalized) {
    throw new Error("AI provider token requires a provider id");
  }
  return `${TOKEN_KEY_PREFIX}${normalized}`;
}

// Get API token for a specific provider
export const getProviderApiToken = async (providerId: string): Promise<string | null> => {
  try {
    const token = (await invoke("get_secure_secret", {
      key: tokenKey(providerId),
    })) as string | null;
    return token ?? null;
  } catch (error) {
    console.error(`Error getting ${providerId} API token:`, error);
    return null;
  }
};

// Store API token for a specific provider
export const storeProviderApiToken = async (providerId: string, token: string): Promise<void> => {
  try {
    await invoke("store_secure_secret", {
      key: tokenKey(providerId),
      value: token,
    });
  } catch (error) {
    console.error(`Error storing ${providerId} API token:`, error);
    throw error;
  }
};

// Remove API token for a specific provider
export const removeProviderApiToken = async (providerId: string): Promise<void> => {
  try {
    await invoke("remove_secure_secret", {
      key: tokenKey(providerId),
    });
  } catch (error) {
    console.error(`Error removing ${providerId} API token:`, error);
    throw error;
  }
};

// Validate API key for a specific provider
export const validateProviderApiKey = async (
  providerId: string,
  apiKey: string,
): Promise<boolean> => {
  try {
    // Import provider dynamically to avoid circular dependency
    const { getProvider } = await import("@/features/ai/services/providers/ai-provider-registry");
    const provider = getProvider(providerId);

    if (!provider) {
      console.error(`Provider not found: ${providerId}`);
      return false;
    }

    return await provider.validateApiKey(apiKey);
  } catch (error) {
    console.error(`${providerId} API key validation error:`, error);
    return false;
  }
};
