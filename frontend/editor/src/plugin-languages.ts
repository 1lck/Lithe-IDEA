// Static file types and presentation are independent of language-server ownership.
import type { languages } from "monaco-editor/esm/vs/editor/editor.api.js";

export interface PluginLanguage {
  id: string;
  fileExtensions?: string[];
  fileNames?: string[];
  grammar?: { kind: "monarch"; monarch: languages.IMonarchLanguage } | null;
  configuration?: {
    lineComment?: string;
    blockComment?: [string, string];
    brackets?: [string, string][];
    autoClosingPairs?: [string, string][];
  } | null;
}
const owned = new Map<string, { key: string; language: PluginLanguage; providers: { dispose(): void }[] }>();
export function hasPluginGrammar(id: string): boolean { return !!owned.get(id)?.language.grammar; }
export function hasPluginLanguage(id: string): boolean { return owned.has(id); }
export function pluginLanguageForFilename(filename: string): string | undefined {
  const name = filename.toLowerCase();
  const list = [...owned.values()].map(value => value.language);
  return list.find(language => language.fileNames?.some(file => file.toLowerCase() === name))?.id
    ?? list.flatMap(language => (language.fileExtensions ?? []).map(extension => ({ id: language.id, extension: withDot(extension).toLowerCase() })))
      .filter(value => name.endsWith(value.extension)).sort((a, b) => b.extension.length - a.extension.length)[0]?.id;
}
export function toLanguageConfiguration(configuration: PluginLanguage["configuration"]): languages.LanguageConfiguration {
  const pairs = (configuration?.autoClosingPairs ?? []).map(([open, close]) => ({ open, close }));
  return {
    comments: configuration?.lineComment || configuration?.blockComment
      ? { lineComment: configuration.lineComment, blockComment: configuration.blockComment } : undefined,
    brackets: configuration?.brackets, autoClosingPairs: pairs, surroundingPairs: pairs,
  };
}
const withDot = (extension: string) => extension.startsWith(".") ? extension : `.${extension}`;
export type MonacoLanguages = Pick<typeof languages, "getLanguages" | "register" | "setLanguageConfiguration">;

/** The caller supplies the worker-isolated engine; this pure registry never runs plugin regexes. */
export function setPluginLanguages(monaco: MonacoLanguages, list: readonly PluginLanguage[],
  installGrammar: (id: string, grammar: languages.IMonarchLanguage) => { dispose(): void } = () => ({ dispose() {} }),
): { failed: { id: string; message: string }[]; removed: string[] } {
  const failed: { id: string; message: string }[] = [], removed: string[] = [];
  const next = new Map(list.filter(language => language?.id).map(language => [language.id, language]));
  for (const [id, current] of owned) {
    if (next.has(id)) continue;
    current.providers.forEach(provider => provider.dispose()); owned.delete(id); removed.push(id);
  }
  for (const [id, language] of next) {
    const key = JSON.stringify(language);
    if (owned.get(id)?.key === key) continue;
    owned.get(id)?.providers.forEach(provider => provider.dispose()); owned.delete(id);
    // Monaco cannot unregister file associations; matching above uses only live contributions.
    if (!monaco.getLanguages().some(registered => registered.id === id)) monaco.register({ id });
    const providers: { dispose(): void }[] = [];
    try {
      if (language.grammar) providers.push(installGrammar(id, language.grammar.monarch));
      if (language.configuration) providers.push(monaco.setLanguageConfiguration(id, toLanguageConfiguration(language.configuration)));
      owned.set(id, { key, language, providers });
    } catch (error) {
      providers.forEach(provider => provider.dispose());
      failed.push({ id, message: error instanceof Error ? error.message : String(error) });
    }
  }
  return { failed, removed };
}
