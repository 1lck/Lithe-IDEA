import type { DeclarativePluginSummary } from "./declarative-plugin-launch";

export type PluginListState = "enabled" | "disabled" | "quarantined";

export interface PluginListFilters {
  query: string;
  capability: "all" | "language";
  state: "all" | PluginListState;
  source: "all" | DeclarativePluginSummary["source"];
}

export const EMPTY_PLUGIN_LIST_FILTERS: PluginListFilters = {
  query: "",
  capability: "all",
  state: "all",
  source: "all",
};

export function pluginListState(plugin: DeclarativePluginSummary): PluginListState {
  if (plugin.status === "rejected") return "quarantined";
  return plugin.enabled ? "enabled" : "disabled";
}

export function pluginListIdentity(plugin: Pick<DeclarativePluginSummary, "pluginId" | "source">): string {
  return `${plugin.source}:${plugin.pluginId}`;
}

/** Filter only facts present in the scan summary; installed is a location, not a trust claim. */
export function groupPluginList(plugins: readonly DeclarativePluginSummary[], filters: PluginListFilters) {
  const terms = filters.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const groups: Record<PluginListState, DeclarativePluginSummary[]> = {
    enabled: [],
    disabled: [],
    quarantined: [],
  };
  for (const plugin of plugins) {
    const state = pluginListState(plugin);
    if (filters.state !== "all" && filters.state !== state) continue;
    if (filters.source !== "all" && filters.source !== plugin.source) continue;
    if (filters.capability === "language" && !plugin.languages.length) continue;
    const searchable = `${plugin.displayName}\n${plugin.pluginId}`.toLowerCase();
    if (!terms.every((term) => searchable.includes(term))) continue;
    groups[state].push(plugin);
  }
  // Code-point ordering is stable across OS locale and never mutates the host snapshot.
  const compare = (left: string, right: string) => left < right ? -1 : left > right ? 1 : 0;
  return (["enabled", "disabled", "quarantined"] as const).map((state) => ({
    state,
    plugins: groups[state].sort((a, b) =>
      compare(a.displayName.toLowerCase(), b.displayName.toLowerCase())
      || compare(pluginListIdentity(a), pluginListIdentity(b))),
  })).filter((group) => group.plugins.length > 0);
}
