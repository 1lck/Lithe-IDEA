import type { Settings } from "@/features/settings/types/settings.types";

type UiRootPreferences = Pick<
  Settings,
  "reduceMotion" | "showStatusBar" | "windowChromeDensity" | "compactMode"
>;

export function getUiRootAttributes(settings: UiRootPreferences) {
  return {
    "data-reduce-motion": settings.reduceMotion ? "true" : "system",
    "data-status-bar": settings.showStatusBar ? "visible" : "hidden",
    "data-window-chrome-density": settings.windowChromeDensity,
    "data-compact-mode": settings.compactMode ? "true" : "false",
  } as const;
}

export function shouldShowTabCloseButton(
  visibility: Settings["tabCloseButtonVisibility"],
  isActive: boolean,
  isPinned: boolean,
) {
  return isPinned || visibility === "always" || (visibility === "active" && isActive);
}
