import { useEffect, useState } from "react";
import {
  listDeclarativePlugins,
  loadDeclarativeSettingSnapshot,
} from "./declarative-plugin-launch";
import { pluginPlanGuard, subscribePluginActivity } from "./declarative-plugin-lifecycle";
import {
  registerPluginSettingsPages,
  type PluginSettingsPage,
  type PluginSettingsContribution,
} from "./declarative-settings-pages";

export function useDeclarativeSettingsPages(enabled: boolean) {
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<{
    revision: number;
    pages: PluginSettingsPage[];
    error: string | null;
  } | null>(null);
  useEffect(() => subscribePluginActivity(() => setRevision((value) => value + 1)), []);
  useEffect(() => {
    if (!enabled) {
      setState(null);
      return;
    }
    let cancelled = false;
    const guard = pluginPlanGuard();
    void (async () => {
      const catalog = await listDeclarativePlugins();
      const contributions: PluginSettingsContribution[] = [];
      const errors: string[] = [];
      for (const plugin of catalog) {
        if (cancelled) return;
        if (plugin.status !== "accepted" || !plugin.enabled) continue;
        try {
          guard(plugin.pluginId);
          const snapshot = await loadDeclarativeSettingSnapshot(plugin.pluginId, "");
          guard(plugin.pluginId);
          contributions.push({
            pluginId: plugin.pluginId,
            displayName: plugin.displayName,
            settings: snapshot.settings,
            actions: snapshot.settingActions,
            languageId: plugin.primaryLanguageId,
          });
        } catch (error) {
          errors.push(`${plugin.pluginId}: ${String(error)}`);
        }
      }
      if (!cancelled)
        setState({
          revision,
          pages: registerPluginSettingsPages(contributions),
          error: errors.length ? errors.join("; ") : null,
        });
    })().catch((error: unknown) => {
      if (!cancelled) setState({ revision, pages: [], error: String(error) });
    });
    return () => {
      cancelled = true;
    };
  }, [enabled, revision]);
  return enabled && state?.revision === revision ? state : { pages: [], error: null };
}
