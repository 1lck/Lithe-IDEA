import {
  DEFAULT_LOCALE,
  DEFAULT_DISPLAY_LANGUAGE,
  DISPLAY_LANGUAGES,
  sharedCatalogs,
  type DisplayLanguage,
} from "./shared.generated";
export { DISPLAY_LANGUAGES, LANGUAGE_OPTIONS, DEFAULT_DISPLAY_LANGUAGE } from "./shared.generated";
export type { DisplayLanguage } from "./shared.generated";

const catalogs: Readonly<Record<string, Readonly<Record<string, string>>>> = sharedCatalogs;
export type TranslationKey = keyof (typeof sharedCatalogs)["en-US"];

export function normalizeDisplayLanguage(value: unknown): DisplayLanguage {
  return typeof value === "string" && (DISPLAY_LANGUAGES as readonly string[]).includes(value)
    ? (value as DisplayLanguage)
    : DEFAULT_DISPLAY_LANGUAGE;
}

export function getLocaleCatalog(language: DisplayLanguage) {
  return catalogs[normalizeDisplayLanguage(language)];
}

export function createTranslator(language: DisplayLanguage) {
  const catalog = getLocaleCatalog(language);
  const fallback = catalogs[DEFAULT_LOCALE];
  return (key: string, values?: Record<string, string | number>): string => {
    const text = Object.prototype.hasOwnProperty.call(catalog, key)
      ? catalog[key]
      : Object.prototype.hasOwnProperty.call(fallback, key)
        ? fallback[key]
        : key;
    // Substitute once: user values containing another placeholder remain data.
    return text.replace(/\{([a-zA-Z][a-zA-Z0-9]*)\}/g, (placeholder, name: string) =>
      values && Object.prototype.hasOwnProperty.call(values, name)
        ? String(values[name])
        : placeholder,
    );
  };
}
