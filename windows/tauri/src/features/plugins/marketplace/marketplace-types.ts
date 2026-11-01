import type { PreparedDeclarativeInstall } from "../declarative-plugin-launch";

/**
 * Marketplace browse types for contract v1. The shapes mirror the
 * Core-normalized index in `rust/lithe-core/src/plugins/marketplace.rs` and
 * the host marketplace commands; the frontend renders availability and never
 * selects a release, archive URL, platform, or signing identity itself.
 */

/** One plugin as Core normalized it from a marketplace index. */
export interface MarketplaceIndexEntry {
  id: string;
  name: string;
  author: string;
  repository: string;
  homepage?: string | null;
  description: string;
  /** Translations of `description` keyed by language tag such as `zh-Hans`. */
  localizedDescriptions?: Record<string, string>;
  tags?: string[];
  license: string;
  icon?: string | null;
  /** Platforms of the latest listed version. */
  platforms?: string[];
  latestVersion?: string;
  latestReleaseDate?: string;
  availability: MarketplaceAvailability;
}

/** What this host can do with the entry's newest installable version. */
export type MarketplaceAvailability =
  | {
      status: "available";
      version: string;
      pluginAPIVersion?: number;
      releaseDate?: string;
      downloadURL?: string;
      sha256?: string;
    }
  | {
      status: "unsupported";
      code: string;
      platform?: string;
      message?: string;
    };

/** An index entry Core refused; `id` is null when the entry had no usable ID. */
export interface MarketplaceRejectedEntry {
  id: string | null;
  error: { code: string; message: string; path: string | null };
}

export interface MarketplaceIndex {
  plugins: MarketplaceIndexEntry[];
  rejected: MarketplaceRejectedEntry[];
}

/** One enabled source's cached catalog, as `list` returns it. */
export interface MarketplaceSourceIndex {
  sourceId: string;
  sourceName: string;
  index: MarketplaceIndex | null;
  problem: string | null;
}

/** The review a finished `prepare` returns; `prepared` is the exact object the
 * approval card must render and `confirm` must commit, never a re-derivation. */
export interface MarketplaceReview {
  operationId: string;
  sourceId: string;
  sourceName: string;
  indexUrl: string;
  /** Only the host's verified conclusion may show an official badge. */
  officialPublisherVerified: boolean;
  requiresConfirmation: boolean;
  prepared: PreparedDeclarativeInstall;
}

export interface MarketplaceInstallation {
  pluginId: string;
  version: string;
  enabled: boolean;
}

/**
 * Dependency-injected marketplace backend. The Tauri service module in
 * `../declarative-marketplace` binds to this port one-to-one; the page never
 * invents another IPC group or fakes a connected backend.
 */
export interface DeclarativeMarketplaceService {
  list(): Promise<MarketplaceSourceIndex[]>;
  refresh(operationId: string, sourceId: string): Promise<MarketplaceIndex>;
  prepare(
    operationId: string,
    sourceId: string,
    pluginId: string,
  ): Promise<MarketplaceReview>;
  confirm(
    operationId: string,
    manifestDigest: string,
    approved: boolean,
  ): Promise<MarketplaceInstallation>;
  cancel(operationId: string): Promise<void>;
}

/** How one installed package reached this machine. Marketplace installs keep
 * the source they came from; disk imports and bundled packages stay outside
 * the marketplace so no same-ID entry can take them over. */
export type MarketplaceInstalledChannel =
  | { kind: "bundled" }
  | { kind: "disk" }
  | { kind: "unknown" }
  | { kind: "marketplace"; sourceId: string; sourceName: string };

export interface MarketplaceInstalledPlugin {
  pluginId: string;
  version: string;
  channel: MarketplaceInstalledChannel;
}

/** Reads the installed snapshot the page reconciles its states against. */
export type MarketplaceInstalledProvider = () => Promise<MarketplaceInstalledPlugin[]>;

/** What the marketplace can do with one entry on one source, mirroring the
 * macOS `PluginMarketplaceInstallState` semantics. */
export type MarketplaceInstallState =
  | { kind: "installable" }
  | { kind: "installed"; version: string }
  | { kind: "updateAvailable"; installed: string; available: string }
  | { kind: "installedFromOtherSource"; sourceName: string }
  | { kind: "managedOutsideMarketplace"; version: string }
  | {
      kind: "unsupported";
      reason: "platform" | "api" | "unknown";
      /** Host platform identifier, when the entry named one. */
      platform?: string;
      message: string;
    };

/** One source's listing of a plugin. */
export interface MarketplaceOffer {
  sourceId: string;
  sourceName: string;
  entry: MarketplaceIndexEntry;
}

function compareSemanticVersions(left: string, right: string): number {
  const parse = (value: string): number[] | null => {
    const parts = value.split(".");
    if (parts.length !== 3) return null;
    const numbers = parts.map((part) => Number(part));
    return numbers.every((number) => Number.isInteger(number) && number >= 0)
      ? numbers
      : null;
  };
  const leftNumbers = parse(left);
  const rightNumbers = parse(right);
  // Core validated both versions; anything unexpected compares as "not newer"
  // so the row keeps a truthful installed state instead of offering an update.
  if (!leftNumbers || !rightNumbers) return 0;
  for (let position = 0; position < 3; position += 1) {
    if (leftNumbers[position] !== rightNumbers[position]) {
      return leftNumbers[position] - rightNumbers[position];
    }
  }
  return 0;
}

/**
 * Installs consider the installed package first: a disk or bundled package is
 * never managed by a marketplace entry, and an update is only offered by the
 * source the plugin was installed from. Unavailable entries report why.
 */
export function marketplaceInstallState(
  offer: MarketplaceOffer,
  installed: MarketplaceInstalledPlugin | undefined,
): MarketplaceInstallState {
  if (installed) {
    if (installed.channel.kind !== "marketplace") {
      return { kind: "managedOutsideMarketplace", version: installed.version };
    }
    if (installed.channel.sourceId !== offer.sourceId) {
      return { kind: "installedFromOtherSource", sourceName: installed.channel.sourceName };
    }
    if (offer.entry.availability.status === "available") {
      const available = offer.entry.availability.version;
      if (compareSemanticVersions(available, installed.version) > 0) {
        return { kind: "updateAvailable", installed: installed.version, available };
      }
    }
    return { kind: "installed", version: installed.version };
  }
  const availability = offer.entry.availability;
  if (availability.status === "available") return { kind: "installable" };
  return {
    kind: "unsupported",
    reason:
      availability.code === "plugin.index.platformUnsupported"
        ? "platform"
        : availability.code === "plugin.index.apiUnsupported"
          ? "api"
          : "unknown",
    platform: availability.platform,
    message: availability.message ?? availability.code,
  };
}

/** The offer a shared plugin ID shows: the install source when it still lists
 * the plugin (updates stay fixed to it), then the first enabled source. */
export function selectMarketplaceOffer(
  offers: MarketplaceOffer[],
  installed: MarketplaceInstalledPlugin | undefined,
): MarketplaceOffer | null {
  if (offers.length === 0) return null;
  const channel = installed?.channel;
  if (channel?.kind === "marketplace") {
    const recorded = offers.find((offer) => offer.sourceId === channel.sourceId);
    if (recorded) return recorded;
  }
  return offers[0];
}

/** Case-insensitive substring match over the fields a user would search,
 * including every localized description, mirroring the macOS matcher. */
export function marketplaceEntryMatches(entry: MarketplaceIndexEntry, rawQuery: string): boolean {
  const query = rawQuery.trim().toLowerCase();
  if (!query) return true;
  const haystack = [
    entry.name,
    entry.author,
    entry.description,
    entry.id,
    ...(entry.tags ?? []),
    ...Object.values(entry.localizedDescriptions ?? {}),
  ];
  return haystack.some((value) => value.toLowerCase().includes(query));
}

/** `description` in the UI language, falling back to the primary subtag and
 * then to the index default, exactly like the other platform. */
export function marketplaceEntryDescription(
  entry: MarketplaceIndexEntry,
  uiLanguage: string,
): string {
  const localized = entry.localizedDescriptions;
  if (!localized) return entry.description;
  if (Object.prototype.hasOwnProperty.call(localized, uiLanguage)) {
    return localized[uiLanguage];
  }
  const primary = uiLanguage.split("-")[0];
  const tag = Object.keys(localized).find((key) => key.split("-")[0] === primary);
  return tag ? localized[tag] : entry.description;
}
