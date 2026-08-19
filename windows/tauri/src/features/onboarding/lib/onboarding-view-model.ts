import type { OnboardingContext } from "./onboarding-state";

type Translator = (key: string, values?: Record<string, string | number>) => string;

export interface OnboardingViewModel {
  title: string;
  description: string;
  showSettings: boolean;
  primaryAction: "open-folder" | "finish";
  primaryLabel: string;
  secondaryLabel?: string;
}

export function buildOnboardingViewModel(
  context: OnboardingContext,
  t: Translator,
): OnboardingViewModel {
  if (context.mode === "updated" || context.mode === "release-notes") {
    const versionCopy = context.previousVersion
      ? t("onboarding.updatedFromVersion", {
          previousVersion: context.previousVersion,
          currentVersion: context.currentVersion,
        })
      : t("onboarding.versionInstalled", { version: context.currentVersion });

    return {
      title: t("onboarding.whatsNewTitle", { version: context.currentVersion }),
      description:
        context.mode === "updated" ? versionCopy : t("onboarding.releaseNotesDescription"),
      showSettings: false,
      primaryAction: "finish",
      primaryLabel: t("ui.done"),
    };
  }

  return {
    title: t("onboarding.welcomeTitle"),
    description: t("onboarding.welcomeDescription", { version: context.currentVersion }),
    showSettings: true,
    primaryAction: "open-folder",
    primaryLabel: t("welcome.openFolder"),
    secondaryLabel: t("ui.done"),
  };
}
