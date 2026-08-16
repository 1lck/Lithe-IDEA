import type { IconThemeDefinition } from "./icon-theme.types";

function isLegacyLitheIconTheme(theme: IconThemeDefinition) {
  return (
    theme.id === "lithe-icons-dimmed" ||
    theme.id === "lithe-icons-light" ||
    theme.id === "lithe-file-icons" ||
    theme.id === "lithe-file-icons-dark" ||
    theme.id === "lithe-file-icons-light" ||
    theme.name === "Lithe (Dark)" ||
    theme.name === "Lithe (Dimmed)" ||
    theme.name === "Lithe (Light)" ||
    theme.name === "Lithe File Icons"
  );
}

export function getVisibleIconThemes(themes: IconThemeDefinition[]) {
  return themes.filter((theme) => !isLegacyLitheIconTheme(theme));
}
