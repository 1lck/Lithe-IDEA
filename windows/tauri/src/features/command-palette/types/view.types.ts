type BuiltInCommandPaletteViewId =
  | "root"
  | "color-theme"
  | "icon-theme"
  | "local-history"
  | "outline"
  | "encoding";

type ExtensionCommandPaletteViewId = `extension:${string}`;

export type CommandPaletteViewId = BuiltInCommandPaletteViewId | ExtensionCommandPaletteViewId;
