import { describe, expect, test } from "bun:test";
import {
  marketplaceEntryDescription,
  marketplaceEntryMatches,
  marketplaceInstallState,
  selectMarketplaceOffer,
  type MarketplaceIndexEntry,
  type MarketplaceInstalledPlugin,
  type MarketplaceOffer,
} from "./marketplace-types";

function availableAvailability(version: string) {
  return {
    status: "available" as const,
    version,
    pluginAPIVersion: 1,
    releaseDate: "2026-01-01",
    downloadURL: "https://github.com/example/fixture/releases/download/fixture.zip",
    sha256: "a".repeat(64),
  };
}

function availableEntry(overrides: Partial<MarketplaceIndexEntry> = {}): MarketplaceIndexEntry {
  return {
    id: "io.example.fixture",
    name: "Fixture",
    author: "example",
    repository: "https://github.com/example/fixture",
    homepage: null,
    description: "A fixture plugin.",
    localizedDescriptions: {},
    tags: [],
    license: "MIT",
    icon: null,
    platforms: ["windows-x64"],
    latestVersion: "1.0.0",
    latestReleaseDate: "2026-01-01",
    availability: availableAvailability("1.0.0"),
    ...overrides,
  };
}

function offer(
  entry: MarketplaceIndexEntry,
  sourceId = "lithe-official",
  sourceName = "Lithe",
): MarketplaceOffer {
  return { sourceId, sourceName, entry };
}

function installed(
  version: string,
  channel: MarketplaceInstalledPlugin["channel"],
  pluginId = "io.example.fixture",
): MarketplaceInstalledPlugin {
  return { pluginId, version, channel };
}

describe("marketplaceInstallState", () => {
  test("an uninstalled available entry is installable", () => {
    expect(marketplaceInstallState(offer(availableEntry()), undefined)).toEqual({
      kind: "installable",
    });
  });

  test("the same source reports installed, or an update when a newer version is listed", () => {
    const sameSource = installed("1.0.0", {
      kind: "marketplace",
      sourceId: "lithe-official",
      sourceName: "Lithe",
    });
    expect(marketplaceInstallState(offer(availableEntry()), sameSource)).toEqual({
      kind: "installed",
      version: "1.0.0",
    });
    const newer = availableEntry({
      availability: availableAvailability("1.2.0"),
    });
    expect(marketplaceInstallState(offer(newer), sameSource)).toEqual({
      kind: "updateAvailable",
      installed: "1.0.0",
      available: "1.2.0",
    });
  });

  test("an older or malformed listed version never offers a downgrade", () => {
    const sameSource = installed("2.0.0", {
      kind: "marketplace",
      sourceId: "lithe-official",
      sourceName: "Lithe",
    });
    const older = availableEntry({
      availability: availableAvailability("1.9.9"),
    });
    expect(marketplaceInstallState(offer(older), sameSource)).toEqual({
      kind: "installed",
      version: "2.0.0",
    });
    const malformed = availableEntry({
      availability: availableAvailability("2.0"),
    });
    expect(marketplaceInstallState(offer(malformed), sameSource)).toEqual({
      kind: "installed",
      version: "2.0.0",
    });
  });

  test("an installed version wins over an unavailable listing", () => {
    const sameSource = installed("1.0.0", {
      kind: "marketplace",
      sourceId: "lithe-official",
      sourceName: "Lithe",
    });
    const unavailable = availableEntry({
      availability: {
        status: "unsupported",
        code: "plugin.index.platformUnsupported",
        platform: "windows-x64",
        message: "This plugin is not available for windows-x64.",
      },
    });
    expect(marketplaceInstallState(offer(unavailable), sameSource)).toEqual({
      kind: "installed",
      version: "1.0.0",
    });
  });

  test("another marketplace source keeps the installation; disk and bundled entries are never taken over", () => {
    const entry = availableEntry();
    const fromOther = installed("1.0.0", {
      kind: "marketplace",
      sourceId: "source-b",
      sourceName: "Lithe Store",
    });
    expect(marketplaceInstallState(offer(entry, "lithe-official"), fromOther)).toEqual({
      kind: "installedFromOtherSource",
      sourceName: "Lithe Store",
    });
    expect(
      marketplaceInstallState(offer(entry), installed("1.0.0", { kind: "disk" })),
    ).toEqual({ kind: "managedOutsideMarketplace", version: "1.0.0" });
    expect(
      marketplaceInstallState(offer(entry), installed("1.0.0", { kind: "bundled" })),
    ).toEqual({ kind: "managedOutsideMarketplace", version: "1.0.0" });
  });

  test("unavailable entries name the platform or API reason", () => {
    const platform = availableEntry({
      availability: {
        status: "unsupported",
        code: "plugin.index.platformUnsupported",
        platform: "windows-x64",
        message: "This plugin is not available for windows-x64.",
      },
    });
    expect(marketplaceInstallState(offer(platform), undefined)).toEqual({
      kind: "unsupported",
      reason: "platform",
      platform: "windows-x64",
      message: "This plugin is not available for windows-x64.",
    });
    const api = availableEntry({
      availability: {
        status: "unsupported",
        code: "plugin.index.apiUnsupported",
        platform: "windows-x64",
        message: "This plugin requires a newer version of Lithe.",
      },
    });
    expect(marketplaceInstallState(offer(api), undefined)).toEqual({
      kind: "unsupported",
      reason: "api",
      platform: "windows-x64",
      message: "This plugin requires a newer version of Lithe.",
    });
    const unknown = availableEntry({
      availability: {
        status: "unsupported",
        code: "plugin.index.future",
      },
    });
    expect(marketplaceInstallState(offer(unknown), undefined)).toEqual({
      kind: "unsupported",
      reason: "unknown",
      platform: undefined,
      message: "plugin.index.future",
    });
  });
});

describe("selectMarketplaceOffer", () => {
  const first = offer(availableEntry({ name: "From official" }), "lithe-official");
  const second = offer(availableEntry({ name: "From store" }), "source-b", "Lithe Store");

  test("the recorded install source wins over source order", () => {
    const recorded = installed("1.0.0", {
      kind: "marketplace",
      sourceId: "source-b",
      sourceName: "Lithe Store",
    });
    expect(selectMarketplaceOffer([first, second], recorded)?.sourceId).toBe("source-b");
  });

  test("without an installed source the first enabled source is shown", () => {
    expect(selectMarketplaceOffer([first, second], undefined)?.sourceId).toBe("lithe-official");
    expect(selectMarketplaceOffer([], undefined)).toBeNull();
  });
});

describe("marketplaceEntryMatches", () => {
  const entry = availableEntry({
    tags: ["zig"],
    localizedDescriptions: { "zh-Hans": "示例插件" },
  });

  test("matches name, ID, tags, and localized text case-insensitively", () => {
    expect(marketplaceEntryMatches(entry, "FIX")).toBe(true);
    expect(marketplaceEntryMatches(entry, "io.example")).toBe(true);
    expect(marketplaceEntryMatches(entry, "ZIG")).toBe(true);
    expect(marketplaceEntryMatches(entry, "示例")).toBe(true);
    expect(marketplaceEntryMatches(entry, "  ")).toBe(true);
    expect(marketplaceEntryMatches(entry, "no-such-plugin")).toBe(false);
  });
});

describe("marketplaceEntryDescription", () => {
  const entry = availableEntry({
    description: "Default text",
    localizedDescriptions: { en: "English text", "zh-Hans": "简体中文说明" },
  });

  test("an exact tag wins, then the primary subtag, then the index default", () => {
    expect(marketplaceEntryDescription(entry, "zh-Hans")).toBe("简体中文说明");
    expect(marketplaceEntryDescription(entry, "zh-CN")).toBe("简体中文说明");
    expect(marketplaceEntryDescription(entry, "en-US")).toBe("English text");
    expect(marketplaceEntryDescription(entry, "fr-FR")).toBe("Default text");
  });
});
