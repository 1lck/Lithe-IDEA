import { MONACO_TOKEN_SYNTAX_ROLES, createMonacoTokenStyleRules } from "@lithe/editor/token-theme-roles";
import type * as Monaco from "monaco-editor";
import type { ThemeDefinition } from "@/extensions/themes/theme.types";
import { toMonacoTokenForeground } from "./color";

export const MONACO_TOKEN_THEME_INHERITS_BASE = false;


const INVALID_TOKEN_NAMES = ["invalid", "string.invalid", "number.invalid"];

function syntaxTokenColor(theme: ThemeDefinition, token: string): string | undefined {
  return (
    theme.syntaxTokens?.[`--color-syntax-${token}`] ??
    theme.syntaxTokens?.[`--syntax-${token}`] ??
    theme.syntaxTokens?.[`--color-${token}`] ??
    theme.syntaxTokens?.[`--${token}`]
  );
}

function themeColor(theme: ThemeDefinition, token: string): string | undefined {
  return (
    theme.cssVariables[`--color-${token}`] ??
    theme.cssVariables[`--${token}`] ??
    syntaxTokenColor(theme, token)
  );
}

export function createMonacoTokenThemeRules(
  theme: ThemeDefinition,
  italicComments: boolean,
): Monaco.editor.ITokenThemeRule[] {
  const syntaxRules = MONACO_TOKEN_SYNTAX_ROLES.flatMap(([token, syntaxName]) => {
    const foreground = toMonacoTokenForeground(syntaxTokenColor(theme, syntaxName));
    const italicComment = italicComments && syntaxName === "comment";
    if (!foreground && !italicComment) return [];

    return [
      {
        token,
        ...(foreground ? { foreground } : {}),
        ...(italicComment ? { fontStyle: "italic" } : {}),
      },
    ];
  });

  const invalidForeground = toMonacoTokenForeground(themeColor(theme, "destructive"));
  const invalidRules = invalidForeground
    ? INVALID_TOKEN_NAMES.map((token) => ({ token, foreground: invalidForeground }))
    : [];

  return [
    ...syntaxRules,
    ...invalidRules,
    ...createMonacoTokenStyleRules(italicComments),
  ];
}
