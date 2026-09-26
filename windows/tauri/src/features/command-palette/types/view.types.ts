type BuiltInCommandPaletteViewId =
  | "root"
  | "color-theme"
  | "icon-theme"
  | "local-history"
  | "outline"
  | "databases"
  | "encoding";

type ExtensionCommandPaletteViewId = `extension:${string}`;

export type CommandPaletteViewId = BuiltInCommandPaletteViewId | ExtensionCommandPaletteViewId;
