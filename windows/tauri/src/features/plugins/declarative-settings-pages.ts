import type {
  DeclarativePluginSetting,
  DeclarativeSettingAction,
} from "./declarative-plugin-launch";

export interface PluginSettingsContribution {
  pluginId: string;
  displayName: string;
  settings: DeclarativePluginSetting[];
  actions: DeclarativeSettingAction[];
  languageId: string | null;
}
export interface PluginSettingsPage {
  id: `plugin-settings:${string}`;
  title: string;
  group: "languages" | "build";
  page: NonNullable<DeclarativePluginSetting["page"]>;
  contributions: PluginSettingsContribution[];
}
export function settingsPageId(
  page: NonNullable<DeclarativePluginSetting["page"]>,
): `plugin-settings:${string}` {
  return `plugin-settings:${page.languageID ? "language:" + page.languageID : "build:" + page.buildSystemID}`;
}
/** Placement only. Declarations are already Core-normalized; values, scopes
 * and effects are never interpreted by this route registry. No-page items
 * remain in plugin details and never create an anonymous settings page. */
export function registerPluginSettingsPages(
  contributions: PluginSettingsContribution[],
): PluginSettingsPage[] {
  const pages = new Map<string, PluginSettingsPage>();
  for (const plugin of contributions) {
    const placements = [...plugin.settings, ...plugin.actions].flatMap((item) =>
      item.page ? [item.page] : [],
    );
    for (const page of placements) {
      const id = settingsPageId(page);
      if (!pages.has(id))
        pages.set(id, {
          id,
          page,
          group: page.languageID ? "languages" : "build",
          title: page.languageID ?? page.buildSystemID ?? "",
          contributions: [],
        });
      const route = pages.get(id)!;
      if (route.contributions.some((entry) => entry.pluginId === plugin.pluginId)) continue;
      route.contributions.push({
        ...plugin,
        languageId: page.languageID ?? plugin.languageId,
        settings: plugin.settings.filter((item) => item.page && settingsPageId(item.page) === id),
        actions: plugin.actions.filter((item) => item.page && settingsPageId(item.page) === id),
      });
    }
  }
  return [...pages.values()].sort((a, b) => a.id.localeCompare(b.id));
}
