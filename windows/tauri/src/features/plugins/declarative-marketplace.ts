import { invoke } from "@/platform/tauri-core";
import type { PreparedDeclarativeInstall } from "./declarative-plugin-launch";
import type { MarketplaceIndex } from "./marketplace/marketplace-types";

/** Core-normalized index; consumers render availability rather than selecting a
 * release, archive URL, platform or signing identity in the frontend. */
export type DeclarativeMarketplaceIndex = MarketplaceIndex;

export interface DeclarativeMarketplaceSourceIndex {
  sourceId: string;
  sourceName: string;
  index: DeclarativeMarketplaceIndex | null;
  problem: string | null;
  /** Keyed by plugin ID within this source. Absent on older hosts: callers
   * should obtain fresh native eligibility before offering an update. */
  installations?: Record<string, DeclarativeMarketplaceInstallationState>;
}

export interface DeclarativeMarketplaceInstallationState {
  origin: "none" | "marketplace" | "disk" | "bundled" | "unknown";
  version: string | null;
  enabled: boolean | null;
  sourceId: string | null;
  /** Includes Core's platform/API availability and the original-source rule.
   * Preparation and confirmation still repeat the authoritative checks. */
  canPrepare: boolean;
}

export interface DeclarativeMarketplaceReview {
  operationId: string;
  sourceId: string;
  sourceName: string;
  indexUrl: string;
  officialPublisherVerified: boolean;
  requiresConfirmation: boolean;
  prepared: PreparedDeclarativeInstall;
}

export interface DeclarativeMarketplaceInstallation {
  pluginId: string;
  version: string;
  enabled: boolean;
}

export function listDeclarativeMarketplace(): Promise<DeclarativeMarketplaceSourceIndex[]> {
  return invoke("declarative_marketplace_list");
}

/** Callers own a unique operation ID and cancel it on page teardown. The native
 * window is injected by Tauri and cannot be selected by this service. */
export function refreshDeclarativeMarketplace(
  operationId: string,
  sourceId: string,
): Promise<DeclarativeMarketplaceIndex> {
  return invoke("declarative_marketplace_refresh", { operationId, sourceId });
}

export function prepareDeclarativeMarketplace(
  operationId: string,
  sourceId: string,
  pluginId: string,
): Promise<DeclarativeMarketplaceReview> {
  return invoke("declarative_marketplace_prepare", { operationId, sourceId, pluginId });
}

export function confirmDeclarativeMarketplace(
  operationId: string,
  manifestDigest: string,
  approved: boolean,
): Promise<DeclarativeMarketplaceInstallation> {
  return invoke("declarative_marketplace_confirm", { operationId, manifestDigest, approved });
}

export function cancelDeclarativeMarketplace(operationId: string): Promise<void> {
  return invoke("declarative_marketplace_cancel", { operationId });
}
