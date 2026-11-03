import github from "../themes/github.json";
import one from "../themes/one.json";
import vscode from "../themes/vscode.json";
import idea from "../themes/idea.json";

import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import { vs, vs_dark } from "monaco-editor/esm/vs/editor/standalone/common/themes.js";

import { MONACO_TOKEN_SYNTAX_ROLES, createMonacoTokenStyleRules } from "./token-theme-roles";

export interface WorkbenchThemeInput {
  id: string;
  dark: boolean;
  syntaxScheme?: "lithe" | "github" | "one" | "vscode" | "idea";
  italicComments?: boolean;
  custom?: { name: string; dark: boolean; colors: Record<string, string>;
    tokens: Record<string, { foreground?: string; fontStyle?: string }> };
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
  if (input.custom) input = { ...input, dark: input.custom.dark,
    colors: { ...(input.dark === input.custom.dark ? input.colors : {}), ...input.custom.colors } };
  const appearance = input.dark ? "dark" : "light";
  // Token names such as "constructor" must never resolve through Object.prototype.
  const syntaxColors = new Map(Object.entries(palette.defaults).map(([role, value]) => [role, value[appearance]]));
  // Reuse the same bundled palettes as Windows. These only replace syntax
  // colors; workbench surfaces continue to follow the native interface theme.
  const scheme = input.syntaxScheme === "github" ? github : input.syntaxScheme === "one" ? one
    : input.syntaxScheme === "vscode" ? vscode : input.syntaxScheme === "idea" ? idea : undefined;
  const variant = scheme?.themes.find(value => value.id === `${input.syntaxScheme}-${appearance}`);
  if (variant) {
    const syntax: Record<string, string> = variant.syntax;
    const aliases: Record<string, string> = {
      annotation: "attribute", documentationComment: "comment", field: "property",
      functionCall: "function", functionDeclaration: "function", parameter: "variable", typeParameter: "type",
    };
    for (const role of syntaxColors.keys()) {
      const color = syntax[aliases[role] ?? role];
      if (color) syntaxColors.set(role, color);
    }
    for (const [role, color] of Object.entries(syntax)) syntaxColors.set(role, color);
  }
  const tokens = new Map(syntaxColors);
  for (const [token, role] of MONACO_TOKEN_SYNTAX_ROLES) {
    const color = syntaxColors.get(token) ?? syntaxColors.get(nativeRoles[role] ?? role);
    if (color) tokens.set(token, color);
  }
  if (input.syntaxScheme === "idea") {
    // Keep Monaco's UI defaults, but resolve every inherited syntax foreground
    // through this palette. Otherwise a more specific VS rule wins over IDEA
    // (keyword.flow, operator.swift, attribute.value.html, etc.).
    tokens.set("", syntaxColors.get("text")!);
    for (const rule of (input.dark ? vs_dark : vs).rules) {
      if (!rule.foreground || rule.token === "invalid" || tokens.has(rule.token)) continue;
      let parent = rule.token;
      while (parent && !tokens.has(parent)) parent = parent.slice(0, Math.max(0, parent.lastIndexOf(".")));
      tokens.set(rule.token, tokens.get(parent)!);
    }
    // SQL's inherited Monaco rules override generic colors (red strings,
    // magenta builtins, slate operators). Resolve the language roles explicitly.
    for (const [token, role] of [
      ["string.sql", "string"], ["operator.sql", "text"],
      ["operator.sql.word", "keyword"], ["predefined.sql", "text"],
      ["predefined.sql.keyword", "keyword"], ["keyword.sql", "keyword"],
      ["number.sql", "number"], ["comment.sql", "comment"],
      ["comment.quote.sql", "comment"], ["delimiter.sql", "text"],
      ["delimiter.parenthesis.sql", "text"], ["delimiter.square.sql", "text"],
    ]) tokens.set(token, syntaxColors.get(role)!);
    // Community YAMLHighlighter: keys -> KEYWORD, plain/block scalars -> TEXT,
    // quoted scalars -> STRING, comments -> DOC_COMMENT, anchors/tags -> IDENTIFIER.
    // Keep the language suffix: changing generic type/string would recolor Java and JSON.
    for (const [token, role] of [
      ["type.yaml", "keyword"], ["string.yaml", "string"], ["string.yaml.plain", "text"],
      ["number.yaml", "text"], ["keyword.yaml", "text"],
      ["comment.yaml", "documentationComment"], ["tag.yaml", "text"],
      ["namespace.yaml", "text"], ["operators.yaml", "text"],
      ["string.escape.yaml", "string"],
    ]) tokens.set(token, syntaxColors.get(role)!);
    for (const kind of ["float", "octal", "hex", "infinity", "nan", "date"])
      tokens.set(`number.${kind}.yaml`, syntaxColors.get("text")!);
    // Light overrides YAML_ANCHOR explicitly instead of inheriting IDENTIFIER.
    if (!input.dark) {
      tokens.set("namespace.yaml", "#0000e6");
      tokens.set("tag.yaml", "#0000e6");
    }
    // Java METHOD_CALL inherits the identifier color. Darcula's STATIC_METHOD
    // has font attributes but no foreground; declarations use FUNCTION_DECLARATION.
    // Keep lexical Java names neutral until the language server classifies them.
    const text = syntaxColors.get("text")!;
    tokens.set("function.java", text);
    for (const prefix of ["method", "method.readonly", "method.deprecated", "method.readonly.deprecated"]) {
      tokens.set(prefix, text);
      tokens.set(`${prefix}.declaration`, syntaxColors.get("functionDeclaration")!);
      tokens.set(`${prefix}.static`, text);
      tokens.set(`${prefix}.declaration.static`, text);
    }
  }
  const colors: Record<string, string> = {
    "editor.foreground": input.colors?.foreground ?? syntaxColors.get("text")!,
    // Keep the minimap shadow and overview ruler border from forming vertical separators.
    "scrollbar.shadow": "#00000000",
    "editorOverviewRuler.border": "#00000000",
    "editorOverviewRuler.wordHighlightForeground": "#00000000",
    "editorOverviewRuler.wordHighlightStrongForeground": "#00000000",
    "editorOverviewRuler.wordHighlightTextForeground": "#00000000",
  };
  const surfaceColors: [keyof NonNullable<WorkbenchThemeInput["colors"]>, string[]][] = [
    // Monaco otherwise fills the right overview ruler from tokenizer defaults when the minimap is enabled.
    ["background", ["editor.background", "editorGutter.background", "editorStickyScroll.background",
      "editorStickyScrollGutter.background", "minimap.background", "editorOverviewRuler.background"]],
    ["cursor", ["editorCursor.foreground"]],
    ["selection", ["editor.selectionBackground", "editor.inactiveSelectionBackground"]],
    ["lineHighlight", ["editor.lineHighlightBackground"]],
    ["lineNumber", ["editorLineNumber.foreground"]],
    ["activeLineNumber", ["editorLineNumber.activeForeground"]],
    ["guide", ["editorIndentGuide.background1", ...Array.from({ length: 6 }, (_, index) => `editorBracketPairGuide.background${index + 1}`)]],
    ["activeGuide", ["editorIndentGuide.activeBackground1", ...Array.from({ length: 6 }, (_, index) => `editorBracketPairGuide.activeBackground${index + 1}`)]],
    ["link", ["editorLink.activeForeground"]],
  ];
  for (const [role, monacoKeys] of surfaceColors) {
    const value = input.colors?.[role];
    if (value) for (const key of monacoKeys) colors[key] = value;
  }
  // Apply custom styles after the built-in language overrides, including their more-specific aliases.
  if (input.custom?.colors.foreground) tokens.set("", input.custom.colors.foreground);
  const customRules: monaco.editor.ITokenThemeRule[] = [];
  const custom = input.custom?.tokens;
  if (custom) {
    const candidates = new Set([...tokens.keys(), ...Object.keys(custom),
      ...createMonacoTokenStyleRules(false).map(rule => rule.token)]);
    const aliases = new Map(MONACO_TOKEN_SYNTAX_ROLES);
    for (const token of candidates) {
      let key = token;
      while (key && !Object.hasOwn(custom, key)) key = key.slice(0, Math.max(0, key.lastIndexOf(".")));
      const role = aliases.get(token);
      const parts = token.split(".");
      const method = parts[0] === "method";
      const declaration = method && parts.includes("declaration");
      const staticMethod = method && parts.includes("static");
      const semantic = staticMethod ? custom[declaration ? "method.declaration.static" : "method.static"]
        : declaration ? custom["method.declaration"] ?? custom.functionDeclaration : undefined;
      const style = semantic ?? ((declaration || staticMethod) ? undefined : custom[key] ?? (role ? custom[role] : undefined));
      if (style) customRules.push({ token, ...(style.foreground ? { foreground: style.foreground.slice(1) } : {}),
        ...(style.fontStyle !== undefined ? { fontStyle: [style.fontStyle, ...(parts.includes("deprecated") ? ["strikethrough"] : [])].filter(Boolean).join(" ") } : {}) });
    }
  }
  const name = themeName(input.id);
  monaco.editor.defineTheme(name, {
    base: input.dark ? "vs-dark" : "vs", inherit: true, colors,
    rules: [...[...tokens].map(([token, foreground]) => ({ token, foreground: foreground.slice(1) })),
      { token: "comment", fontStyle: input.italicComments ? "italic" : "" },
      { token: "documentationComment", fontStyle: input.italicComments ? "italic" : "" },
      ...createMonacoTokenStyleRules(input.italicComments === true), ...customRules],
  });
  return name;
}

export function installThemes(palette: SyntaxPalette) {
  for (const appearance of ["light", "dark"] as const) {
    defineWorkbenchTheme({ id: appearance, dark: appearance === "dark" }, palette);
  }
}
