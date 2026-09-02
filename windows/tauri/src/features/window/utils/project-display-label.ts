import type { ProjectTab } from "../stores/workspace-tabs.store";

export type ProjectDisplayLabelSource = Pick<ProjectTab, "name" | "displayAlias">;

export function formatProjectDisplayLabel(name: string, displayAlias?: string): string {
  const alias = displayAlias?.trim();
  if (!alias) {
    return name;
  }

  return `${name} (${alias})`;
}

export function getProjectDisplayLabel(project: ProjectDisplayLabelSource): string {
  return formatProjectDisplayLabel(project.name, project.displayAlias);
}
