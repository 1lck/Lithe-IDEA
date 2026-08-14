const RETIRED_EXTENSION_IDS = new Set(["lithe.theme.market"]);

export function isRetiredExtensionId(extensionId: string): boolean {
  return RETIRED_EXTENSION_IDS.has(extensionId);
}

export function filterRetiredExtensions<T extends { id: string }>(extensions: T[]): T[] {
  return extensions.filter((extension) => !isRetiredExtensionId(extension.id));
}
