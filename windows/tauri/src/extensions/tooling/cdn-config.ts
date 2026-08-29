const EXTENSIONS_CDN_ENV_NAME = "EXTENSIONS_CDN_BASE_URL";

export function resolveExtensionsCdnBaseUrl(value: string | undefined): string {
  const baseUrl = value?.trim().replace(/\/+$/, "") || "";
  if (!baseUrl) {
    throw new Error(
      `${EXTENSIONS_CDN_ENV_NAME} is required before generating or verifying extension CDN content.`,
    );
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(baseUrl);
  } catch {
    throw new Error(`${EXTENSIONS_CDN_ENV_NAME} must be an absolute HTTP(S) URL.`);
  }

  if (parsedUrl.protocol !== "http:" && parsedUrl.protocol !== "https:") {
    throw new Error(`${EXTENSIONS_CDN_ENV_NAME} must be an absolute HTTP(S) URL.`);
  }
  if (baseUrl.includes("?") || baseUrl.includes("#")) {
    throw new Error(`${EXTENSIONS_CDN_ENV_NAME} must not contain a query or fragment.`);
  }

  return baseUrl;
}

export function requireExtensionsCdnBaseUrl(): string {
  return resolveExtensionsCdnBaseUrl(process.env.EXTENSIONS_CDN_BASE_URL);
}
