import { create } from "zustand";
import { useUIExtensionStore } from "@/extensions/ui/stores/ui-extension-store";
import { assertPluginActive } from "./declarative-plugin-lifecycle";
import {
  listDeclarativePlugins,
  listDeclarativeWebWindows,
  getDeclarativePluginManifest,
  openDeclarativeWebWindow,
  type DeclarativeWebToolWindow,
} from "./declarative-plugin-launch";

interface DeclaredCommand {
  id: string;
  title: string;
  toolWindowID: string;
  placements: string[];
  order?: number;
}
export const useDeclarativePluginUI = create<{ windows: DeclarativeWebToolWindow[] }>(() => ({
  windows: [],
}));
let refreshSequence = 0;
const revisions = new Map<string, number>();
const appliedRefreshes = new Map<string, number>();
const registered = new Set<string>();

export function removeDeclarativeUI(pluginId: string): void {
  revisions.set(pluginId, (revisions.get(pluginId) ?? 0) + 1);
  const owner = `declarative:${pluginId}`;
  useUIExtensionStore.getState().actions.cleanupExtension(owner);
  registered.delete(pluginId);
  useDeclarativePluginUI.setState((state) => ({
    windows: state.windows.filter((window) => window.pluginId !== pluginId),
  }));
}

/** Reuse the presentation registries, never the Worker loader or interpreter. */
export async function refreshDeclarativeUI(): Promise<void> {
  const current = ++refreshSequence;
  const observedRevisions = new Map(revisions);
  const [plugins, windows] = await Promise.all([
    listDeclarativePlugins(),
    listDeclarativeWebWindows(),
  ]);
  const declarations = await Promise.all(
    plugins
      .filter((plugin) => plugin.enabled && plugin.status === "accepted")
      .map(async (plugin) => ({
        plugin,
        manifest: await getDeclarativePluginManifest(plugin.pluginId),
      })),
  );
  const actions = useUIExtensionStore.getState().actions;
  const pluginIds = new Set([...registered, ...plugins.map((plugin) => plugin.pluginId)]);
  for (const pluginId of pluginIds) {
    // A new refresh can start after revocation (for example another plugin's
    // successful reload). A catalog entry alone does not grant admission.
    try {
      assertPluginActive(pluginId);
    } catch {
      continue;
    }
    // Revoking B must neither resurrect B nor cancel an unrelated refresh of A.
    if (
      (observedRevisions.get(pluginId) ?? 0) !== (revisions.get(pluginId) ?? 0) ||
      current < (appliedRefreshes.get(pluginId) ?? 0)
    )
      continue;
    appliedRefreshes.set(pluginId, current);
    const owner = `declarative:${pluginId}`;
    actions.cleanupExtension(owner);
    registered.delete(pluginId);
    const declaration = declarations.find(({ plugin }) => plugin.pluginId === pluginId);
    const ownedWindows = declaration
      ? windows.filter((window) => window.pluginId === pluginId)
      : [];
    useDeclarativePluginUI.setState((state) => ({
      windows: [...state.windows.filter((window) => window.pluginId !== pluginId), ...ownedWindows],
    }));
    if (!declaration) continue;
    const { plugin, manifest } = declaration;
    const ui = manifest?.ui as { commands?: DeclaredCommand[] } | undefined;
    registered.add(pluginId);
    for (const command of [...(ui?.commands ?? [])].sort(
      (a, b) => (a.order ?? 0) - (b.order ?? 0) || a.id.localeCompare(b.id),
    )) {
      if (
        !windows.some(
          (window) =>
            window.pluginId === plugin.pluginId && window.windowId === command.toolWindowID,
        )
      )
        continue;
      const execute = () => openDeclarativeWebWindow(plugin.pluginId, command.toolWindowID);
      const id = `${owner}:${command.id}`;
      actions.registerCommand({
        id,
        extensionId: owner,
        title: command.title,
        category: plugin.displayName,
        placements: command.placements,
        execute,
      });
      if (command.placements.includes("toolbar"))
        actions.registerToolbarAction({
          id,
          extensionId: owner,
          title: command.title,
          icon: "puzzle",
          position: "right",
          onClick: () => {
            void execute().catch(console.error);
          },
        });
    }
  }
}
