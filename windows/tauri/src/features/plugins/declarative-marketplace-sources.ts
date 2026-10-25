import { invoke } from "@/platform/tauri-core";

/**
 * Host API for declarative marketplace source management. The Rust
 * `plugin_host::marketplace_sources` module owns the list: preset sources are
 * rebuilt from host constants, the official source can be disabled but never
 * removed, and URL resolution is decided by Core
 * (`plugins.marketplace.resolveSource`). Index fetching, downloads, and
 * installation are later M2 slices and deliberately absent here.
 */

export interface DeclarativeMarketplaceSource {
  id: string;
  name: string;
  /** What the user entered, or the official index URL for a preset. */
  input: string;
  indexURL: string;
  repository: string | null;
  isEnabled: boolean;
  kind: "official" | "thirdParty";
  isOfficial: boolean;
  deletable: boolean;
}

export interface DeclarativeMarketplaceSourcesState {
  sources: DeclarativeMarketplaceSource[];
  /**
   * Present when the persisted sources file was corrupted: the original
   * bytes were preserved next to the store and the list rebuilt from
   * presets. The user's data is never silently reset.
   */
  problem: string | null;
}

/** Returns the current sources; presets are rebuilt by the host. */
export function listDeclarativeMarketplaceSources(): Promise<DeclarativeMarketplaceSourcesState> {
  return invoke<DeclarativeMarketplaceSourcesState>("declarative_marketplace_sources_state");
}

/**
 * Resolves and adds a third-party source through Core. Rejects duplicates
 * (same stable ID or same index URL in any casing) with a stable
 * `plugin.marketplace.sourceAlreadyAdded` error, and passes Core's
 * `plugin.source.invalid` rejections through.
 */
export function addDeclarativeMarketplaceSource(url: string): Promise<DeclarativeMarketplaceSource[]> {
  return invoke<DeclarativeMarketplaceSource[]>("declarative_marketplace_sources_add", { url });
}

/** Enables or disables one source; unknown IDs are a host-side no-op. */
export function setDeclarativeMarketplaceSourceEnabled(
  sourceId: string,
  enabled: boolean,
): Promise<DeclarativeMarketplaceSource[]> {
  return invoke<DeclarativeMarketplaceSource[]>("declarative_marketplace_sources_set_enabled", {
    sourceId,
    enabled,
  });
}

/**
 * Removes a deletable source. The official source is refused by the host
 * (`plugin.marketplace.officialSourceCannotBeRemoved`); removing Lithe Store
 * persists its removal across restarts.
 */
export function removeDeclarativeMarketplaceSource(sourceId: string): Promise<DeclarativeMarketplaceSource[]> {
  return invoke<DeclarativeMarketplaceSource[]>("declarative_marketplace_sources_remove", { sourceId });
}
