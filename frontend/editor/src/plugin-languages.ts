// Plugin languages with a grammar (`languages` 2). Rust Core has validated each
// grammar; the editor registers the language, applies the Monarch tokenizer and
// editor configuration, and replaces them all when the host sends a new list.
import type { languages } from "monaco-editor/esm/vs/editor/editor.api.js";
import { toMonacoLanguageId } from "./language";

/** One `plugins.declarative.decodeGrammar` language as the host forwards it. */
export interface PluginLanguage {
  id: string;
  fileExtensions?: string[];
  fileNames?: string[];
  grammar: { kind: "monarch"; monarch: languages.IMonarchLanguage };
  configuration?: {
    lineComment?: string;
    blockComment?: [string, string];
    brackets?: [string, string][];
    autoClosingPairs?: [string, string][];
  } | null;
}

const owned = new Map<string, { key: string; providers: { dispose(): void }[] }>();

/** Whether a plugin grammar, not a built-in tokenizer, highlights the language. */
export function hasPluginGrammar(monacoLanguageId: string): boolean {
  return owned.has(monacoLanguageId);
}

/** Monaco's configuration for the contract's comment and bracket fields. */
export function toLanguageConfiguration(configuration: PluginLanguage["configuration"]): languages.LanguageConfiguration {
  const pairs = (configuration?.autoClosingPairs ?? []).map(([open, close]) => ({ open, close }));
  return {
    comments: configuration?.lineComment || configuration?.blockComment
      ? { lineComment: configuration.lineComment, blockComment: configuration.blockComment } : undefined,
    brackets: configuration?.brackets,
    autoClosingPairs: pairs,
    surroundingPairs: pairs,
  };
}

const withDot = (extension: string) => extension.startsWith(".") ? extension : `.${extension}`;

/** The part of Monaco's `languages` namespace plugin grammars use. */
export type MonacoLanguages = Pick<typeof languages,
  "getLanguages" | "register" | "setMonarchTokensProvider" | "setLanguageConfiguration">;

/**
 * Makes `list` the complete set of plugin grammars. A grammar Monaco cannot
 * compile leaves its language as plain text and is reported back; the other
 * languages still apply.
 */
export function setPluginLanguages(monaco: MonacoLanguages, list: readonly PluginLanguage[]): { failed: { id: string; message: string }[] } {
  const failed: { id: string; message: string }[] = [];
  const next = new Map(list.filter(language => language?.grammar?.kind === "monarch")
    .map(language => [toMonacoLanguageId(language.id), language] as const));
  for (const [id, current] of owned) {
    if (next.has(id)) continue;
    current.providers.forEach(provider => provider.dispose());
    owned.delete(id);
  }
  for (const [id, language] of next) {
    const key = JSON.stringify(language);
    if (owned.get(id)?.key === key) continue;
    owned.get(id)?.providers.forEach(provider => provider.dispose());
    owned.delete(id);
    // Monaco cannot unregister a language, so file matching only grows; a
    // removed plugin's files then open without its tokenizer.
    if (!monaco.getLanguages().some(registered => registered.id === id)) {
      monaco.register({ id, extensions: (language.fileExtensions ?? []).map(withDot), filenames: language.fileNames ?? [] });
    }
    const providers: { dispose(): void }[] = [];
    try {
      providers.push(monaco.setMonarchTokensProvider(id, language.grammar.monarch));
      providers.push(monaco.setLanguageConfiguration(id, toLanguageConfiguration(language.configuration)));
      owned.set(id, { key, providers });
    } catch (error) {
      providers.forEach(provider => provider.dispose());
      failed.push({ id: language.id, message: error instanceof Error ? error.message : String(error) });
    }
  }
  return { failed };
}
