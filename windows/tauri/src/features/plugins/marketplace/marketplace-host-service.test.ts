import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import type { DeclarativePluginSummary } from "../declarative-plugin-launch";
import type { DeclarativeMarketplaceInstallationState, DeclarativeMarketplaceSourceIndex } from "../declarative-marketplace";
import { marketplaceInstallState, type MarketplaceOffer } from "./marketplace-types";

const calls: Array<{ command: string; args: unknown }> = [];
let responses = new Map<string, unknown>();
let invokeFailure: Error | null = null;
const cleanupGates: Array<() => void> = [];

mock.module("@/platform/tauri-core", () => ({
  invoke: async (command: string, args: unknown) => {
    calls.push({ command, args });
    if (invokeFailure) throw invokeFailure;
    if (!responses.has(command)) throw new Error(`unexpected command: ${command}`);
    return responses.get(command);
  },
}));
// Keep the real catalog-list wrapper while isolating unrelated launch adapters.
mock.module("@/features/workspace/runtime/workspace-runtime-registry", () => ({ workspaceRuntimeRegistry: {} }));
mock.module("@/features/file-system/stores/file-system.store", () => ({ useFileSystemStore: {} }));
mock.module("../declarative-plugin-lifecycle", () => ({ pluginPlanGuard: {} }));
mock.module("../plugin-web-appearance", () => ({ getPluginWebAppearance: () => ({}) }));

const { marketplaceHostService, marketplaceInstalledSnapshot, listMarketplaceInstalledPlugins } =
  await import("./marketplace-host-service");

beforeEach(() => {
  calls.length = 0;
  responses = new Map();
  invokeFailure = null;
});
afterEach(() => { cleanupGates.splice(0).forEach((release) => release()); });

const pluginId = "io.example.fixture";
function plugin(source: DeclarativePluginSummary["source"] = "installed"): DeclarativePluginSummary {
  return {
    pluginId, source, displayName: "Fixture", version: "1.0.0", apiVersion: 1,
    enabled: true, status: "accepted", languages: [], declaredSettings: [],
    declaresTests: false, primaryLanguageId: null, rejection: null,
  };
}
function installation(overrides: Partial<DeclarativeMarketplaceInstallationState> = {}): DeclarativeMarketplaceInstallationState {
  return { origin: "marketplace", version: "1.1.0", enabled: true, sourceId: "source-a", canPrepare: true, ...overrides };
}
function source(sourceId: string, record?: DeclarativeMarketplaceInstallationState): DeclarativeMarketplaceSourceIndex {
  return {
    sourceId, sourceName: sourceId === "source-a" ? "Original source" : "Other source",
    index: null, problem: null, ...(record ? { installations: { [pluginId]: record } } : {}),
  };
}
function offer(sourceId: string): MarketplaceOffer {
  return {
    sourceId, sourceName: sourceId,
    entry: {
      id: pluginId, name: "Fixture", author: "example", repository: "https://example.invalid/plugin",
      description: "Fixture", license: "MIT", availability: { status: "available", version: "2.0.0" },
    },
  };
}

test("native provenance permits an update only from the recorded source, even when its record is reported by another catalog", () => {
  const installed = marketplaceInstalledSnapshot([
    source("source-b", installation()), source("source-a"),
  ], [plugin()])[0]!;
  expect(marketplaceInstallState(offer("source-a"), installed)).toEqual({
    kind: "updateAvailable", installed: "1.1.0", available: "2.0.0",
  });
  expect(marketplaceInstallState(offer("source-b"), installed)).toEqual({
    kind: "installedFromOtherSource", sourceName: "Original source",
  });
});

test.each(["disk", "bundled", "unknown"] as const)("%s native provenance cannot be taken over by a same-ID marketplace entry", (origin) => {
  const installed = marketplaceInstalledSnapshot([source("source-a", installation({ origin, sourceId: null }))], [plugin()])[0]!;
  expect(marketplaceInstallState(offer("source-a"), installed)).toEqual({ kind: "managedOutsideMarketplace", version: "1.1.0" });
});

test("a bundled catalog package remains unmanaged even if the native installed record has the same ID", () => {
  const installed = marketplaceInstalledSnapshot([source("source-a", installation())], [plugin("bundled")])[0]!;
  expect(installed.channel).toEqual({ kind: "bundled" });
  expect(marketplaceInstallState(offer("source-a"), installed)).toEqual({ kind: "managedOutsideMarketplace", version: "1.0.0" });
});

test.each([
  ["absent record", undefined],
  ["no recorded installation", installation({ origin: "none" })],
  ["null source ID", installation({ sourceId: null })],
  ["empty source ID", installation({ sourceId: "" })],
] as const)(
  "%s never infers ownership from catalog position",
  (_scenario, record) => {
    const installed = marketplaceInstalledSnapshot([source("source-a", record)], [plugin()])[0]!;
    expect(marketplaceInstallState(offer("source-a"), installed).kind).toBe("managedOutsideMarketplace");
    expect(installed.channel).toEqual({ kind: "unknown" });
  },
);

test("removing the recorded source does not let a remaining source take its package", () => {
  const installed = marketplaceInstalledSnapshot([source("source-b", installation())], [plugin()])[0]!;
  expect(marketplaceInstallState(offer("source-b"), installed)).toEqual({
    kind: "installedFromOtherSource", sourceName: "source-a",
  });
});

test("an absent record from the first source does not hide a later authoritative installation", () => {
  const installed = marketplaceInstalledSnapshot([
    source("source-b", installation({ origin: "none", version: null, sourceId: null })),
    source("source-a", installation({ version: null })),
  ], [plugin()])[0]!;
  expect(marketplaceInstallState(offer("source-a"), installed)).toEqual({
    kind: "updateAvailable", installed: "1.0.0", available: "2.0.0",
  });
});

test("installed snapshot loads the native catalog and provenance instead of treating every installed package as a marketplace install", async () => {
  responses.set("declarative_marketplace_list", [source("source-a", installation({ origin: "disk", sourceId: null }))]);
  responses.set("declarative_plugins_state", [plugin()]);
  const installed = await listMarketplaceInstalledPlugins();
  expect(calls).toEqual([
    { command: "declarative_marketplace_list", args: undefined },
    { command: "declarative_plugins_state", args: undefined },
  ]);
  expect(installed[0]!.channel).toEqual({ kind: "disk" });
});

test("browse, refresh, prepare and cancellation bind to real native commands without an install notification", async () => {
  let installedNotifications = 0;
  const service = marketplaceHostService(() => { installedNotifications += 1; });
  const sources = [source("source-a")];
  const index = { plugins: [], rejected: [] };
  const review = { operationId: "review-a", prepared: { manifestDigest: "reviewed-digest" } };
  responses.set("declarative_marketplace_list", sources);
  responses.set("declarative_marketplace_refresh", index);
  responses.set("declarative_marketplace_prepare", review);
  responses.set("declarative_marketplace_cancel", undefined);
  expect(await service.list()).toBe(sources);
  expect(await service.refresh("refresh-a", "source-a")).toBe(index);
  expect<unknown>(await service.prepare("review-a", "source-a", pluginId)).toBe(review);
  await service.cancel("review-a");
  expect(installedNotifications).toBe(0);
  expect(calls).toEqual([
    { command: "declarative_marketplace_list", args: undefined },
    { command: "declarative_marketplace_refresh", args: { operationId: "refresh-a", sourceId: "source-a" } },
    { command: "declarative_marketplace_prepare", args: { operationId: "review-a", sourceId: "source-a", pluginId } },
    { command: "declarative_marketplace_cancel", args: { operationId: "review-a" } },
  ]);
});

test("only a completed native confirmation notifies the parent, preserving the review digest and explicit approval", async () => {
  let resolve!: (value: unknown) => void;
  const result = { pluginId, version: "2.0.0", enabled: true };
  const confirming = new Promise<unknown>((accept) => { resolve = accept; });
  cleanupGates.push(() => resolve(result));
  responses.set("declarative_marketplace_confirm", confirming);
  let notifications = 0;
  const service = marketplaceHostService(() => { notifications += 1; });
  const pending = service.confirm("review-a", "reviewed-digest", true);
  expect(notifications).toBe(0);
  resolve(result);
  expect(await pending).toBe(result);
  expect(notifications).toBe(1);
  expect(calls).toEqual([{ command: "declarative_marketplace_confirm", args: {
    operationId: "review-a", manifestDigest: "reviewed-digest", approved: true,
  } }]);
});

test("a native confirmation refusal reaches the caller and never refreshes the parent as though installation succeeded", async () => {
  invokeFailure = new Error("explicit approval is required");
  let notifications = 0;
  const service = marketplaceHostService(() => { notifications += 1; });
  await expect(service.confirm("review-a", "reviewed-digest", false)).rejects.toBe(invokeFailure);
  expect(notifications).toBe(0);
  expect(calls[0]).toEqual({ command: "declarative_marketplace_confirm", args: {
    operationId: "review-a", manifestDigest: "reviewed-digest", approved: false,
  } });
});
