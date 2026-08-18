export type ProjectPickerMode = "picker" | "new-project" | "clone-repository";

export function getProjectPickerInitialState(mode: ProjectPickerMode) {
  if (mode === "picker") {
    return { commandStep: "picker" as const, newProjectSource: undefined };
  }

  return {
    commandStep: "newProject" as const,
    newProjectSource: mode === "clone-repository" ? ("clone" as const) : undefined,
  };
}
