import type { BuildProviderRunReference } from "@/features/run/types/run.types";
import type { BuildInstance, BuildModel } from "./build-provider-workspace";

export interface BuildTargetChoice { id: string; title: string; reference: BuildProviderRunReference }

/** Only current declared selectors are presented. Core validates the reference
 * again at save and preparation; target names never become commands. */
export function buildTargetChoices(manifest: Record<string, unknown> | undefined, instance: BuildInstance,
  model: BuildModel, projectID?: string): BuildTargetChoice[] {
  if (!projectID || model.truncated || model.projects.filter(project => project.id === projectID).length !== 1) return [];
  type Run = { id: string; name: string; source?: string; execution?: "application" | "service" | "task"; fromTargets?: { tags?: string[] } };
  const system = (manifest?.buildSystems as Array<{ id: string; run?: Run[] }> | undefined)?.find(system => system.id === instance.buildSystemID);
  return model.targets.filter(target => target.projectID === projectID).flatMap(target =>
    (system?.run ?? []).filter(run => run.source === "provider" && (!run.fromTargets?.tags?.length
      || run.fromTargets.tags.some(tag => target.tags.includes(tag)))).map(run => ({
      id: JSON.stringify([target.id, run.id]), title: `${target.name} · ${run.name}`,
      reference: { pluginID: instance.pluginID, buildSystemID: instance.buildSystemID, root: instance.root,
        run: run.id, projectID, targetID: target.id, execution: run.execution ?? "application", userArguments: [] },
    })));
}
