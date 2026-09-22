import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";

import { MONACO_TOKEN_SYNTAX_ROLES, createMonacoTokenStyleRules } from "./token-theme-roles";

export interface WorkbenchThemeInput {
  id: string;
  dark: boolean;
  colors?: {
    background?: string;
    foreground?: string;
    cursor?: string;
    selection?: string;
    lineHighlight?: string;
    lineNumber?: string;
    activeLineNumber?: string;
    guide?: string;
    activeGuide?: string;
    link?: string;
  };
}

type SyntaxPalette = { defaults: Record<string, { light: string; dark: string }> };

// Native palette vocabulary differs from the normalized syntax roles. Keep this
// translation at the palette boundary; token classification is shared with Windows.
const nativeRoles: Record<string, string> = {
  function: "functionDeclaration", attribute: "annotation", regex: "string",
};

function themeName(id: string): string {
  return `lithe-${id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}

export function defineWorkbenchTheme(input: WorkbenchThemeInput, palette: SyntaxPalette): string {
  const appearance = input.dark ? "dark" : "light";
  // Token names such as "constructor" must never resolve through Object.prototype.
  const syntaxColors = new Map(Object.entries(palette.defaults).map(([role, value]) => [role, value[appearance]]));
  const tokens = new Map(syntaxColors);
  for (const [token, role] of MONACO_TOKEN_SYNTAX_ROLES) {
    const color = syntaxColors.get(token) ?? syntaxColors.get(nativeRoles[role] ?? role);
    if (color) tokens.set(token, color);
  }
  const colors: Record<string, string> = {
    "editor.foreground": input.colors?.foreground ?? syntaxColors.get("text")!,
    "editorOverviewRuler.wordHighlightForeground": "#00000000",
    "editorOverviewRuler.wordHighlightStrongForeground": "#00000000",
    "editorOverviewRuler.wordHighlightTextForeground": "#00000000",
  };
  const surfaceColors: [keyof NonNullable<WorkbenchThemeInput["colors"]>, string[]][] = [
    ["background", ["editor.background", "editorGutter.background", "editorStickyScroll.background",
      "editorStickyScrollGutter.background", "minimap.background"]],
    ["cursor", ["editorCursor.foreground"]],
    ["selection", ["editor.selectionBackground", "editor.inactiveSelectionBackground"]],
    ["lineHighlight", ["editor.lineHighlightBackground"]],
    ["lineNumber", ["editorLineNumber.foreground"]],
    ["activeLineNumber", ["editorLineNumber.activeForeground"]],
    ["guide", ["editorIndentGuide.background1"]],
    ["activeGuide", ["editorIndentGuide.activeBackground1"]],
    ["link", ["editorLink.activeForeground"]],
  ];
  for (const [role, monacoKeys] of surfaceColors) {
    const value = input.colors?.[role];
    if (value) for (const key of monacoKeys) colors[key] = value;
  }
  const name = themeName(input.id);
  monaco.editor.defineTheme(name, {
    base: input.dark ? "vs-dark" : "vs", inherit: true, colors,
    rules: [...[...tokens].map(([token, foreground]) => ({ token, foreground: foreground.slice(1) })),
      ...createMonacoTokenStyleRules(false)],
  });
  return name;
}

export function installThemes(palette: SyntaxPalette) {
  for (const appearance of ["light", "dark"] as const) {
    defineWorkbenchTheme({ id: appearance, dark: appearance === "dark" }, palette);
  }
}
