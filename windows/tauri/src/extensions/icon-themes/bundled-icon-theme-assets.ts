type BundledIconThemeAssetMap = Record<string, string>;

const BUNDLED_ICON_THEME_LOADERS: Record<string, () => Promise<BundledIconThemeAssetMap>> = {
  "lithe.icon-theme.idea-icons": () =>
    import("./bundled-assets/idea").then((module) => module.assets),
  "lithe.icon-theme.material": () =>
    import("./bundled-assets/material").then((module) => module.assets),
  "lithe.icon-theme.pierre": () =>
    import("./bundled-assets/pierre").then((module) => module.assets),
  "lithe.icon-theme.symbols": () =>
    import("./bundled-assets/symbols").then((module) => module.assets),
};

export async function loadBundledIconThemeAssets(
  extensionId: string,
): Promise<BundledIconThemeAssetMap | undefined> {
  return BUNDLED_ICON_THEME_LOADERS[extensionId]?.();
}

export function resolveBundledIconThemeAsset(
  assets: BundledIconThemeAssetMap | undefined,
  relativePath: string,
): string | undefined {
  const normalizedPath = relativePath.replace(/\\/g, "/").replace(/^\.\//, "");
  return assets?.[normalizedPath];
}
