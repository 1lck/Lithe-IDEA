import type { Command } from "../types/keymaps.types";

type Translator = (key: string, values?: Record<string, string | number>) => string;

function optionalTranslation(t: Translator, key: string, values?: Record<string, string | number>) {
  const translated = t(key, values);
  return translated === key ? null : translated;
}

function translateDynamicCommandTitle(commandId: string, t: Translator) {
  const foldLevel = /^editor\.foldLevel(\d+)$/.exec(commandId);
  if (foldLevel) {
    return optionalTranslation(t, "keybindings.commands.editor.foldLevel.title", {
      level: foldLevel[1],
    });
  }

  const switchToTab = /^workbench\.switchToTab(\d+)$/.exec(commandId);
  if (switchToTab) {
    return optionalTranslation(t, "keybindings.commands.workbench.switchToTab.title", {
      index: switchToTab[1],
    });
  }

  return null;
}

export function localizeKeymapCommand(command: Command, t: Translator): Command {
  const title =
    translateDynamicCommandTitle(command.id, t) ??
    optionalTranslation(t, `keybindings.commands.${command.id}.title`) ??
    command.title;
  const category =
    command.category ?
      optionalTranslation(t, `keybindings.categories.${command.category}`) ??
      optionalTranslation(t, `commandPalette.categories.${command.category}`) ??
      command.category
    : command.category;
  const description =
    optionalTranslation(t, `keybindings.commands.${command.id}.description`) ??
    command.description;

  return {
    ...command,
    title,
    category,
    description,
  };
}
