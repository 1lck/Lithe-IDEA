import litheThemes from "./builtin/lithe.json";
import { toThemeDefinition } from "./theme-file";
import type { ThemeFile } from "./theme-schema";
import type { ThemeDefinition } from "./theme.types";

export type LitheDefaultThemeType = "dark" | "light";

interface LitheDefaultTheme {
  id: string;
  type: LitheDefaultThemeType;
  colors: Record<string, string>;
  syntax: Record<string, string>;
  definition: ThemeDefinition;
}

const litheThemeFile = litheThemes as ThemeFile;

function prefixRecord(prefix: string, value: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value)) {
    result[`${prefix}${key}`] = entry;
  }
  return result;
}

function toStringRecord(value: object): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry === "string") {
      result[key] = entry;
    }
  }
  return result;
}

function buildDefaultTheme(type: LitheDefaultThemeType): LitheDefaultTheme {
  const theme = litheThemeFile.themes.find((entry) => entry.appearance === type);
  if (!theme) {
    throw new Error(`Missing Lithe ${type} default theme`);
  }

  return {
    id: theme.id,
    type,
    colors: toStringRecord(theme.colors),
    syntax: toStringRecord(theme.syntax ?? {}),
    definition: toThemeDefinition(theme),
  };
}

const LITHE_DEFAULT_THEMES: Record<LitheDefaultThemeType, LitheDefaultTheme> = {
  dark: buildDefaultTheme("dark"),
  light: buildDefaultTheme("light"),
};

export function getLitheDefaultTheme(type: LitheDefaultThemeType): LitheDefaultTheme {
  return LITHE_DEFAULT_THEMES[type];
}

export function getLitheDefaultCssVariables(type: LitheDefaultThemeType): Record<string, string> {
  return prefixRecord("--", getLitheDefaultTheme(type).colors);
}

export function getLitheDefaultSyntaxTokens(type: LitheDefaultThemeType): Record<string, string> {
  return prefixRecord("--syntax-", getLitheDefaultTheme(type).syntax);
}

export function getLitheDefaultColor(
  type: LitheDefaultThemeType,
  name: string,
): string | undefined {
  return getLitheDefaultTheme(type).colors[name];
}

export function getRequiredLitheDefaultColor(type: LitheDefaultThemeType, name: string): string {
  const color = getLitheDefaultColor(type, name);
  if (!color) {
    throw new Error(`Missing Lithe ${type} default color: ${name}`);
  }

  return color;
}

export function getLitheDefaultSyntaxColor(
  type: LitheDefaultThemeType,
  name: string,
): string | undefined {
  return getLitheDefaultTheme(type).syntax[name];
}

export function getRequiredLitheDefaultSyntaxColor(
  type: LitheDefaultThemeType,
  name: string,
): string {
  const color = getLitheDefaultSyntaxColor(type, name);
  if (!color) {
    throw new Error(`Missing Lithe ${type} default syntax color: ${name}`);
  }

  return color;
}
