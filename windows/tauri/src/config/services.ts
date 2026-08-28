import { SERVICE_DEFAULTS } from "@/config/service-defaults";

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

export function getServiceUrls() {
  const websiteBaseUrl = trimTrailingSlash(
    import.meta.env.VITE_WEBSITE_URL?.trim() || SERVICE_DEFAULTS.websiteBaseUrl,
  );
  const extensionsCdnBaseUrl = trimTrailingSlash(
    import.meta.env.VITE_EXTENSIONS_CDN_BASE_URL?.trim() ||
      import.meta.env.VITE_PARSER_CDN_URL?.trim() ||
      SERVICE_DEFAULTS.extensionsCdnBaseUrl,
  );

  return {
    ...SERVICE_DEFAULTS,
    websiteBaseUrl,
    docsUrl: `${websiteBaseUrl}/docs`,
    extensionsCdnBaseUrl,
    skillsRegistryUrl:
      import.meta.env.VITE_SKILLS_REGISTRY_URL?.trim() || SERVICE_DEFAULTS.skillsRegistryUrl,
  };
}
