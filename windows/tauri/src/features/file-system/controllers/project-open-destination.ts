import type { DisplayLanguage } from "@/i18n/locale";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { ProjectOpenDefaultDestination } from "@/features/settings/types/settings.types";
import { showChoiceDialogWithCheckbox } from "@/ui/dialog";

// IntelliJ-aligned destinations: "this-window" replaces the active project, "attach" adds
// the new project as a tab beside it, "new-window" opens a separate app window.
export type ProjectOpenDestination = "new-window" | "this-window" | "attach";

export interface ProjectOpenPromptResult {
  destination: ProjectOpenDestination;
  doNotAskAgain: boolean;
}

export interface ProjectOpenDecision {
  destination: ProjectOpenDestination;
  rememberAfterOpen: boolean;
}

export interface ProjectOpenDestinationRequest {
  projectName: string;
  hasOpenWorkspace: boolean;
  explicitDestination?: ProjectOpenDestination;
}

export interface ProjectWorkspaceState {
  rootFolderPath: string | undefined;
  fileCount: number;
  projectTabCount: number;
}

type ProjectOpenSettingKey = "askWhereToOpenProjects" | "projectOpenDefaultDestination";

export interface ProjectOpenDestinationServices {
  getSettings: () => {
    askWhereToOpenProjects: boolean;
    projectOpenDefaultDestination: ProjectOpenDefaultDestination;
    displayLanguage: DisplayLanguage;
  };
  prompt: (request: {
    projectName: string;
    language: DisplayLanguage;
  }) => Promise<ProjectOpenPromptResult | null>;
  updateSetting: (key: ProjectOpenSettingKey, value: boolean | ProjectOpenDefaultDestination) => Promise<void>;
}

const defaultServices: ProjectOpenDestinationServices = {
  getSettings: () => {
    const { settings } = useSettingsStore.getState();
    return {
      askWhereToOpenProjects: settings.askWhereToOpenProjects,
      projectOpenDefaultDestination: settings.projectOpenDefaultDestination,
      displayLanguage: settings.displayLanguage,
    };
  },
  prompt: async ({ projectName, language }) => {
    const t = createTranslator(language);
    const result = await showChoiceDialogWithCheckbox<ProjectOpenDestination>(
      t("projectOpen.where", { project: projectName }),
      {
        title: t("projectOpen.title"),
        checkboxLabel: t("projectOpen.doNotAskAgain"),
        cancelLabel: t("projectOpen.cancel"),
        choices: [
          { value: "this-window", label: t("projectOpen.thisWindow"), variant: "accent" },
          { value: "new-window", label: t("projectOpen.newWindow") },
          { value: "attach", label: t("projectOpen.attach") },
        ],
      },
    );

    return result
      ? { destination: result.value, doNotAskAgain: result.checked }
      : null;
  },
  updateSetting: async (key, value) => {
    await useSettingsStore.getState().actions.updateSetting(key, value);
  },
};

export async function chooseProjectOpenDestination(
  request: ProjectOpenDestinationRequest,
  services: ProjectOpenDestinationServices = defaultServices,
): Promise<ProjectOpenDecision | null> {
  if (request.explicitDestination) {
    return { destination: request.explicitDestination, rememberAfterOpen: false };
  }

  if (!request.hasOpenWorkspace) {
    // Nothing to replace or attach beside: the first project just opens here.
    return { destination: "attach", rememberAfterOpen: false };
  }

  const settings = services.getSettings();
  if (!settings.askWhereToOpenProjects) {
    return {
      destination: settings.projectOpenDefaultDestination,
      rememberAfterOpen: false,
    };
  }

  const result = await services.prompt({
    projectName: request.projectName,
    language: settings.displayLanguage,
  });
  if (!result) {
    return null;
  }

  return {
    destination: result.destination,
    rememberAfterOpen: result.doNotAskAgain,
  };
}

export async function executeProjectOpenDecision(
  decision: ProjectOpenDecision,
  open: (destination: ProjectOpenDestination) => Promise<boolean>,
  services: ProjectOpenDestinationServices = defaultServices,
): Promise<boolean> {
  const opened = await open(decision.destination);
  if (!opened) {
    return false;
  }

  if (decision.rememberAfterOpen) {
    await services.updateSetting("projectOpenDefaultDestination", decision.destination);
    await services.updateSetting("askWhereToOpenProjects", false);
  }

  return true;
}

export function hasOpenProjectWorkspace(state: ProjectWorkspaceState): boolean {
  return !!state.rootFolderPath || state.fileCount > 0 || state.projectTabCount > 0;
}
