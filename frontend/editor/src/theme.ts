import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";

import { MONACO_TOKEN_SYNTAX_ROLES, createMonacoTokenStyleRules } from "./token-theme-roles";

// Native palette vocabulary differs from the normalized syntax roles. Keep this
// translation at the palette boundary; token classification is shared with Windows.
const nativeRoles: Record<string, string> = {
  function: "functionDeclaration", attribute: "annotation", regex: "string",
};
export function installThemes(palette: { defaults: Record<string, { light: string; dark: string }> }) {
  for (const appearance of ["light", "dark"] as const) {
    // Token names such as "constructor" must never resolve through Object.prototype.
    const colors = new Map(Object.entries(palette.defaults).map(([role, value]) => [role, value[appearance]]));
    const tokens = new Map(colors);
    for (const [token, role] of MONACO_TOKEN_SYNTAX_ROLES) {
      const color = colors.get(token) ?? colors.get(nativeRoles[role] ?? role);
      if (color) tokens.set(token, color);
    }
    monaco.editor.defineTheme(`lithe-${appearance}`, {
      base: appearance === "dark" ? "vs-dark" : "vs", inherit: true,
      colors: { "editor.foreground": colors.get("text")! },
      rules: [...[...tokens].map(([token, foreground]) => ({ token, foreground: foreground.slice(1) })),
        ...createMonacoTokenStyleRules(false)],
    });
  }
}
