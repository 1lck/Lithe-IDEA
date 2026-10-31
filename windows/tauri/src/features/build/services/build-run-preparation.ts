import type { BuildConfigurationRunSelection, BuildModel, BuildPreparedRun, BuildRunLaunch, BuildRunSelection, BuildWork } from "./build-provider-types";
import type { BuildLanguageImport } from "./build-language-import";

/** Match an existing configuration to exact public Provider facts. Names are
 * upstream entry identities; this does not infer a framework or build command. */
export function configurationRunSelection(manifest: Record<string, unknown>, buildSystemID: string,
  model: BuildModel, input: BuildConfigurationRunSelection): BuildRunSelection | undefined {
  const projects = model.projects.filter(project => input.reference ? project.id === input.reference.projectID : project.path === input.projectPath);
  if (projects.length !== 1 || model.truncated) return;
  const targets = model.targets.filter(target => target.projectID === projects[0]!.id
    && (input.reference ? target.id === input.reference.targetID : target.name === input.provider));
  if (targets.length !== 1) return;
  type Declaration = { id: string; source?: string; execution?: string; fromTargets?: { tags?: string[] } };
  const system = (manifest.buildSystems as Array<{ id: string; run?: Declaration[] }> | undefined)?.find(system => system.id === buildSystemID);
  const runs = system?.run?.filter(run => run.source === "provider" && (run.execution ?? "application") === input.launchOptions.execution
    && (!input.reference || run.id === input.reference.run)
    && (!run.fromTargets?.tags?.length || run.fromTargets.tags.some(tag => targets[0]!.tags.includes(tag)))) ?? [];
  if (runs.length !== 1) return;
  const original = input.reference?.userArguments ?? [], options = input.launchOptions;
  // Saved applications predate protocol 10. Their opaque Provider arguments
  // retain the original protocol-4 channel; real typed overrides still need
  // version 10/11 and must never be silently stripped for an older backend.
  const opaqueReference = input.reference && (input.reference.execution ?? "application") === "application"
    && options.execution === "application" && !options.runtimeArguments.length && !Object.keys(options.environment).length
    && options.workingDirectory === undefined && options.entrypoint === undefined && options.debug === undefined
    && JSON.stringify(options.arguments) === JSON.stringify(original);
  return { run: runs[0]!.id, projectID: projects[0]!.id, targetID: targets[0]!.id,
    userArguments: opaqueReference ? [...original] : [], launchOptions: opaqueReference ? undefined : options };
}

/** Core creates and decodes the plan; the existing Run host owns its process. */
export async function prepareBuildRun(workspaceRoot: string, operation: BuildWork, model: BuildModel, selection: BuildRunSelection,
  validate: () => Promise<void>, missing: () => Error): Promise<BuildPreparedRun> {
  const target = model.targets.find(target => target.id === selection.targetID && target.projectID === selection.projectID);
  const project = model.projects.find(project => project.id === selection.projectID);
  if (!target || !project || model.truncated) throw missing();
  const result = await operation.perform("build.prepareRunPlan", { workspaceRoot, run: selection.run, project, target,
    userArguments: selection.userArguments ?? [], launchOptions: selection.launchOptions });
  const decoded = await operation.decode<{ launch: BuildRunLaunch }>("build.decodeRunPreparation", { result, launchOptions: selection.launchOptions });
  const imported = await operation.decode<{ languageImport: BuildLanguageImport | null }>("build.languageImport", { executablePath: operation.tool.tool.executable });
  await validate();
  return { launch: structuredClone(decoded.launch), tool: structuredClone(operation.tool), languageImport: imported.languageImport,
    assertCurrent: operation.current, validate };
}
