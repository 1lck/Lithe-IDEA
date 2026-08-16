const BUNDLED_ICON_THEME_ASSETS = import.meta.glob(
  "../bundled/icon-themes/{lithe,material,pierre,symbols}/**/*.svg",
  {
    eager: true,
    import: "default",
    query: "?url",
  },
) as Record<string, string>;

const BUNDLED_ICON_THEME_DIRECTORIES: Record<string, string> = {
  "lithe.icon-theme.lithe-icons": "lithe",
  "lithe.icon-theme.material": "material",
  "lithe.icon-theme.pierre": "pierre",
  "lithe.icon-theme.symbols": "symbols",
};

export function resolveBundledIconThemeAsset(
  extensionId: string,
  relativePath: string,
): string | undefined {
  const directory = BUNDLED_ICON_THEME_DIRECTORIES[extensionId];
  if (!directory) {
    return undefined;
  }

  const normalizedPath = relativePath.replace(/\\/g, "/").replace(/^\.\//, "");
  return BUNDLED_ICON_THEME_ASSETS[`../bundled/icon-themes/${directory}/${normalizedPath}`];
}
