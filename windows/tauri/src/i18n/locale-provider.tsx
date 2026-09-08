import { createContext, useContext, type ReactNode } from "react";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator, type DisplayLanguage } from "./locale";

interface LocaleContextValue {
  language: DisplayLanguage;
  t: (key: string, values?: Record<string, string | number>) => string;
}

const LocaleContext = createContext<LocaleContextValue | null>(null);

export function LocaleProvider({
  children,
  language: overrideLanguage,
}: {
  children: ReactNode;
  language?: DisplayLanguage;
}) {
  const storedLanguage = useSettingsStore((state) => state.settings.displayLanguage);
  const language = overrideLanguage ?? storedLanguage;

  return (
    <LocaleContext.Provider value={{ language, t: createTranslator(language) }}>
      {children}
    </LocaleContext.Provider>
  );
}

export function useTranslation() {
  const context = useContext(LocaleContext);

  if (!context) {
    throw new Error("useTranslation must be used inside LocaleProvider");
  }

  return context;
}
