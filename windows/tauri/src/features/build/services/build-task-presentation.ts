import type { BuildInstance, BuildModel } from "./build-provider-workspace";

interface DeclaredTask {
  id: string; displayName: string; source?: string; execution?: string; scopes?: string[];
  fromModel?: boolean; requiresUserArguments?: boolean; category?: string[]; group?: string; description?: string;
}
export interface BuildTaskChoice {
  id: string; title: string; task: string; projectID?: string; modelTaskID?: string;
  requiresArguments: boolean; category: string[]; group: string; description?: string;
}
export type BuildTaskRow = { id: string; heading: string } | { id: string; choice: BuildTaskChoice };

/** Presentation selects catalog entries by their declared scope; Core still
 * validates every selected project and task when the user actually runs it. */
export function buildTaskChoices(manifest: Record<string, unknown> | undefined, instance: BuildInstance,
  model: BuildModel, projectID?: string): BuildTaskChoice[] {
  const system = (manifest?.buildSystems as Array<{ id: string; tasks?: DeclaredTask[] }> | undefined)?.find(system => system.id === instance.buildSystemID);
  const declarations = system?.tasks ?? [];
  const project = projectID ? model.projects.find(project => project.id === projectID) : undefined;
  if (projectID && !project) return [];
  const choices: BuildTaskChoice[] = declarations.filter(task => !task.fromModel && task.source === "provider"
    && (task.execution ?? "task") === "task" && task.scopes?.includes(project ? "project" : "workspace")).map(task => ({
      id: `declared:${task.id}`, title: task.displayName, task: task.id, projectID: project?.id,
      requiresArguments: task.requiresUserArguments ?? false, category: task.category ?? [], group: task.group ?? "other", description: task.description,
    }));
  if (project) for (const task of model.tasks.filter(task => task.projectID === project.id && task.execution === "task")) {
    const template = declarations.find(declaration => declaration.id === task.template);
    choices.push({ id: `model:${task.id}`, title: task.displayName ?? task.name, task: task.template, projectID: project.id, modelTaskID: task.id,
      requiresArguments: template?.requiresUserArguments ?? false, category: task.category?.length ? task.category : template?.category ?? [],
      group: task.group ?? template?.group ?? "other", description: task.description ?? template?.description });
  }
  return choices;
}

export function buildTaskRows(choices: BuildTaskChoice[], groupTitle: (group: string) => string): BuildTaskRow[] {
  const groups = new Map<string, { title: string; choices: BuildTaskChoice[] }>();
  for (const choice of choices) {
    const key = JSON.stringify([choice.category, choice.category.length ? "" : choice.group]);
    if (!groups.has(key)) groups.set(key, { title: choice.category.length ? choice.category.join(" / ") : groupTitle(choice.group), choices: [] });
    groups.get(key)!.choices.push(choice);
  }
  return [...groups].flatMap(([key, group]) => [{ id: `heading:${key}`, heading: group.title },
    ...group.choices.map(choice => ({ id: choice.id, choice }))]);
}
