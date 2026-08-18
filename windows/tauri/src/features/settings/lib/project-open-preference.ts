export type ProjectOpenPreference = "ask" | "this-window" | "new-window";

interface ProjectOpenPreferenceSettings {
  askWhereToOpenProjects: boolean;
  openFoldersInNewWindow: boolean;
}

export function getProjectOpenPreference(
  settings: ProjectOpenPreferenceSettings,
): ProjectOpenPreference {
  if (settings.askWhereToOpenProjects) {
    return "ask";
  }

  return settings.openFoldersInNewWindow ? "new-window" : "this-window";
}

export function getProjectOpenPreferencePatch(
  preference: ProjectOpenPreference,
): Partial<ProjectOpenPreferenceSettings> {
  if (preference === "ask") {
    return { askWhereToOpenProjects: true };
  }

  return {
    askWhereToOpenProjects: false,
    openFoldersInNewWindow: preference === "new-window",
  };
}
