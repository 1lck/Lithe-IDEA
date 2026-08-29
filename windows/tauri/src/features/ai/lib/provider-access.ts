export function canUseProviderWithoutApiKey(params: {
  hasStoredKey: boolean;
  requiresApiKey: boolean;
}): boolean {
  return !params.requiresApiKey || params.hasStoredKey;
}
