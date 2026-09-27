import type { ExtensionRunPlan } from "../../../../../Plugins/win/SDK/run-actions";
import type { RunActionItem } from "@/features/run-actions/types/run-action.types";
import type { ExtensionManifest } from "../types/extension-manifest";

export function validateRunPlans(value: unknown, manifest: ExtensionManifest): ExtensionRunPlan[] {
  if (!Array.isArray(value) || value.length > 64) throw new Error("Invalid extension run plans");
  const ids = new Set<string>();
  return value.map((plan: unknown) => {
    if (!plan || typeof plan !== "object") throw new Error("Invalid run plan");
    const p = plan as Record<string, unknown>;
    if (
      !["id", "name", "sourceLabel", "executable"].every(
        (key) =>
          typeof p[key] === "string" &&
          (p[key] as string).length > 0 &&
          (p[key] as string).length < 512,
      ) ||
      !manifest.runActions?.executables.includes(String(p.executable)) ||
      !Array.isArray(p.arguments) ||
      p.arguments.length > 128 ||
      !p.arguments.every(
        (arg) => typeof arg === "string" && arg.length < 4096 && !arg.includes("\0"),
      ) ||
      (p.description !== undefined &&
        (typeof p.description !== "string" || p.description.length > 8192)) ||
      ids.has(String(p.id))
    )
      throw new Error("Invalid or undeclared extension run command");
    ids.add(String(p.id));
    return {
      id: String(p.id),
      name: String(p.name),
      sourceLabel: String(p.sourceLabel),
      executable: String(p.executable),
      arguments: p.arguments as string[],
      ...(typeof p.description === "string" ? { description: p.description } : {}),
    };
  });
}

export async function discoverExtensionActions(
  manifest: ExtensionManifest,
  workspacePath: string,
  reader: (path: string) => Promise<string>,
  discover: (files: Record<string, string>) => Promise<unknown>,
  isActive: () => boolean,
): Promise<RunActionItem[]> {
  if (!isActive() || !manifest.runActions || /^(remote|wsl):\/\//.test(workspacePath)) return [];
  const files: Record<string, string> = Object.create(null);
  await Promise.all(
    manifest.runActions.manifestFiles.map(async (name) => {
      if (!isActive()) return;
      // Only root-level declared files are passed to the worker. Never accept worker paths.
      if (!/^[a-z0-9][a-z0-9_.-]*$/i.test(name)) throw new Error("Invalid extension manifest file");
      try {
        const text = await reader(`${workspacePath.replace(/[\\/]$/, "")}/${name}`);
        if (text.length > 256 * 1024) throw new Error("Project manifest exceeds 256 KB");
        files[name] = text;
      } catch {
        // Absent or unreadable project manifests do not contribute actions.
      }
    }),
  );
  if (!isActive()) return [];
  const plans = validateRunPlans(await discover(files), manifest);
  if (!isActive()) return [];
  return plans.map((plan) => ({
    id: `${manifest.id}:${plan.id}`,
    name: plan.name,
    description: plan.description,
    source: "extension",
    sourceLabel: plan.sourceLabel,
    extensionId: manifest.id,
    workingDirectory: workspacePath,
    pluginCommand: { executable: plan.executable, arguments: plan.arguments },
  }));
}
