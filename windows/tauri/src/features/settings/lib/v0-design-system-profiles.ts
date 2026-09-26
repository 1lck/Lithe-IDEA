export interface V0DesignSystemProfile {
  id: string;
  name: string;
  registryUrl: string;
  description?: string;
  homepage?: string;
  tailwindConfigPath?: string;
  globalsCssPath?: string;
  componentsJsonPath?: string;
}

const MAX_V0_DESIGN_SYSTEMS = 50;
const MAX_FIELD_LENGTH = 500;

function trimOptional(value: unknown, maxLength = MAX_FIELD_LENGTH): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim().slice(0, maxLength);
  return trimmed || undefined;
}

export function createV0DesignSystemId(name: string, registryUrl: string): string {
  const slug = `${name}-${registryUrl}`
    .trim()
    .toLowerCase()
    .replace(/https?:\/\//g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);

  return slug || "v0-design-system";
}

export function normalizeV0DesignSystems(value: unknown): V0DesignSystemProfile[] {
  if (!Array.isArray(value)) return [];

  const seenIds = new Set<string>();
  const seenRegistryUrls = new Set<string>();

  return value
    .map((profile): V0DesignSystemProfile | null => {
      if (!profile || typeof profile !== "object") return null;

      const candidate = profile as Partial<V0DesignSystemProfile>;
      const registryUrl = trimOptional(candidate.registryUrl);
      if (!registryUrl) return null;

      const name = trimOptional(candidate.name, 120) || registryUrl;
      const id = trimOptional(candidate.id, 120) || createV0DesignSystemId(name, registryUrl);
      const description = trimOptional(candidate.description, 240);
      const homepage = trimOptional(candidate.homepage);
      const tailwindConfigPath = trimOptional(candidate.tailwindConfigPath);
      const globalsCssPath = trimOptional(candidate.globalsCssPath);
      const componentsJsonPath = trimOptional(candidate.componentsJsonPath);

      return {
        id,
        name,
        registryUrl,
        ...(description ? { description } : {}),
        ...(homepage ? { homepage } : {}),
        ...(tailwindConfigPath ? { tailwindConfigPath } : {}),
        ...(globalsCssPath ? { globalsCssPath } : {}),
        ...(componentsJsonPath ? { componentsJsonPath } : {}),
      };
    })
    .filter((profile): profile is V0DesignSystemProfile => {
      if (!profile) return false;
      if (seenIds.has(profile.id)) return false;
      if (seenRegistryUrls.has(profile.registryUrl)) return false;
      seenIds.add(profile.id);
      seenRegistryUrls.add(profile.registryUrl);
      return true;
    })
    .slice(0, MAX_V0_DESIGN_SYSTEMS);
}
