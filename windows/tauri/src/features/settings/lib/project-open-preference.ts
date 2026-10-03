import type { ProjectOpenDefaultDestination } from "@/features/settings/types/settings.types";

export type ProjectOpenPreference = "ask" | ProjectOpenDefaultDestination;

interface ProjectOpenPreferenceSettings {
  askWhereToOpenProjects: boolean;
  projectOpenDefaultDestination: ProjectOpenDefaultDestination;
}

export function getProjectOpenPreference(
  settings: ProjectOpenPreferenceSettings,
): ProjectOpenPreference {
  if (settings.askWhereToOpenProjects) {
    return "ask";
  }

  return settings.projectOpenDefaultDestination;
}

export function getProjectOpenPreferencePatch(
  preference: ProjectOpenPreference,
): Partial<ProjectOpenPreferenceSettings> {
  if (preference === "ask") {
    return { askWhereToOpenProjects: true };
  }

  return {
    askWhereToOpenProjects: false,
    projectOpenDefaultDestination: preference,
  };
}
