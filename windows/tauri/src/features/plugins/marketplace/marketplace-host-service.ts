import {
  listDeclarativeMarketplace,
  refreshDeclarativeMarketplace,
  prepareDeclarativeMarketplace,
  confirmDeclarativeMarketplace,
  cancelDeclarativeMarketplace,
  type DeclarativeMarketplaceSourceIndex,
} from "../declarative-marketplace";
import { listDeclarativePlugins, type DeclarativePluginSummary } from "../declarative-plugin-launch";
import type { DeclarativeMarketplaceService, MarketplaceInstalledPlugin } from "./marketplace-types";

/** The native installation record owns provenance. Catalog source only says
 * where a package is stored, and cannot distinguish a disk import from an
 * installation made by a particular marketplace source. Unknown records stay
 * unmanaged until the host can prove their ownership. */
export function marketplaceInstalledSnapshot(
  sources: DeclarativeMarketplaceSourceIndex[],
  plugins: DeclarativePluginSummary[],
): MarketplaceInstalledPlugin[] {
  return plugins.map((plugin) => {
    if (plugin.source === "bundled") {
      return { pluginId: plugin.pluginId, version: plugin.version, channel: { kind: "bundled" } };
    }
    const record = sources.map((source) => source.installations?.[plugin.pluginId])
      .find((state) => state && state.origin !== "none");
    const base = { pluginId: plugin.pluginId, version: record?.version ?? plugin.version };
    if (record?.origin === "marketplace" && record.sourceId) {
      const source = sources.find((item) => item.sourceId === record.sourceId);
      return { ...base, channel: { kind: "marketplace", sourceId: record.sourceId,
        sourceName: source?.sourceName ?? record.sourceId } };
    }
    return { ...base, channel: { kind: record?.origin === "disk" ? "disk" : "unknown" } };
  });
}

export async function listMarketplaceInstalledPlugins(): Promise<MarketplaceInstalledPlugin[]> {
  const [sources, plugins] = await Promise.all([listDeclarativeMarketplace(), listDeclarativePlugins()]);
  return marketplaceInstalledSnapshot(sources, plugins);
}

/** Bind the presentation port to the existing native transaction; a successful
 * commit also refreshes the installed management surface. */
export function marketplaceHostService(onInstalled: () => void): DeclarativeMarketplaceService {
  return {
    list: listDeclarativeMarketplace,
    refresh: refreshDeclarativeMarketplace,
    prepare: prepareDeclarativeMarketplace,
    confirm: async (...args) => {
      const result = await confirmDeclarativeMarketplace(...args);
      onInstalled();
      return result;
    },
    cancel: cancelDeclarativeMarketplace,
  };
}
