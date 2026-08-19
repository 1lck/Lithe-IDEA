import type { Action } from "@/features/command-palette/types/action.types";

type Translator = (key: string, values?: Record<string, string | number>) => string;

function optionalTranslation(t: Translator, key: string) {
  const translated = t(key);
  return translated === key ? null : translated;
}

function translateToggleActionLabel(action: Action, t: Translator) {
  const keyPrefix = `commandPalette.actions.${action.id}`;
  if (/\bDisable\b|\bHide\b/.test(action.label)) {
    return optionalTranslation(t, `${keyPrefix}.disableLabel`);
  }
  if (/\bEnable\b|\bShow\b/.test(action.label)) {
    return optionalTranslation(t, `${keyPrefix}.enableLabel`);
  }
  return null;
}

export function localizeCommandPaletteAction(action: Action, t: Translator): Action {
  const actionKeyPrefix = `commandPalette.actions.${action.id}`;
  const label =
    translateToggleActionLabel(action, t) ??
    optionalTranslation(t, `${actionKeyPrefix}.label`) ??
    action.label;
  const translatedDescription = optionalTranslation(t, `${actionKeyPrefix}.description`);
  const description = translatedDescription ?? (label === action.label ? action.description : label);
  const category =
    optionalTranslation(t, `commandPalette.categories.${action.category}`) ?? action.category;

  return {
    ...action,
    label,
    description,
    category,
  };
}
