import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, StrictMode, useEffect } from "react";
import { create } from "zustand";
import type { Root } from "react-dom/client";
import type { DeclarativePluginSummary, PreparedDeclarativeInstall } from "./declarative-plugin-launch";
import type { PluginDetailsModel } from "./details/plugin-details.types";
import type { DeclarativeMarketplaceService } from "./marketplace/marketplace-types";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const workspace = create<{ projectTabs: Array<{ path: string; isActive: boolean }> }>(() => ({ projectTabs: [] }));
const calls: Array<{ command: string; args: Record<string, unknown> }> = [];
let catalog: DeclarativePluginSummary[] = [];
let intercept: (command: string, args: Record<string, unknown>) => Promise<unknown> | undefined = () => undefined;
let marketplaceMounts = 0;
let marketplaceUnmounts = 0;

function summary(pluginId: string, overrides: Partial<DeclarativePluginSummary> = {}): DeclarativePluginSummary {
  return {
    pluginId, displayName: pluginId, version: "1.0.0", apiVersion: 1,
    source: "installed", enabled: true, status: "accepted", languages: [],
    declaredSettings: [], declaresTests: false, primaryLanguageId: null, rejection: null,
    ...overrides,
  };
}

function detail(plugin: DeclarativePluginSummary): PluginDetailsModel {
  const provenance = {
    version: plugin.version, origin: "unknown" as const, channel: "unknown" as const,
    sourceId: null, sourceName: null, repository: null, fileName: null,
    archiveSha256: null, contentDigest: null, verification: { status: "unknown" as const, keyId: null },
  };
  return {
    identity: { pluginId: plugin.pluginId, source: plugin.source, version: plugin.version },
    displayName: plugin.displayName, vendorName: null, description: null, localizedDescriptions: {},
    apiVersion: 1, enabled: plugin.enabled, status: plugin.status, rejection: plugin.rejection,
    settings: [], primaryLanguageId: null, features: [], permissions: [], programs: [],
    versions: { current: provenance, previous: { ...provenance, version: "0.9.0" }, updateStatus: "unknown" },
    operations: { canSetEnabled: plugin.source === "installed", canUninstall: plugin.source === "installed", canRollback: plugin.source === "installed" },
  };
}

const review: PreparedDeclarativeInstall = {
  sessionId: "test-review", manifestDigest: "test-digest", displayName: "Import fixture",
  review: { pluginId: "io.example.import", version: "1.0.0", permissions: [], programs: [], newPrograms: [] },
};

async function call(command: string, args: Record<string, unknown> = {}): Promise<unknown> {
  calls.push({ command, args });
  const response = intercept(command, args);
  if (response) return response;
  if (command === "rescan") return catalog.length;
  if (command === "list") return catalog.map((plugin) => ({ ...plugin }));
  if (command === "windows") return [];
  if (command === "prepare") return review;
  if (command === "confirm") return catalog[0];
  if (command === "declarative_marketplace_confirm") return catalog[0];
  if (command === "cancel") return;
  const plugin = catalog.find((item) => item.pluginId === args.pluginId
    && (args.source === undefined || item.source === args.source));
  if (!plugin) throw new Error("package not found");
  if (command === "declarative_plugins_details") return detail(plugin);
  if (command === "enabled") plugin.enabled = Boolean(args.enabled);
  else if (command === "rollback") plugin.version = "0.9.0";
  else if (command === "uninstall") catalog = catalog.filter((item) => item !== plugin);
  else throw new Error(`unexpected command ${command}`);
}

mock.module("@/platform/tauri-core", () => ({ invoke: call }));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({ useWorkspaceTabsStore: workspace }));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: (selector: (state: { settings: { displayLanguage: Language } }) => unknown) =>
    selector({ settings: { displayLanguage: "en-US" } }),
}));
mock.module("@/features/keymaps/hooks/use-command-shortcut", () => ({ useCommandShortcut: () => undefined }));
mock.module("@tauri-apps/plugin-dialog", () => ({ open: async () => "C:/fixtures/plugin.zip" }));
mock.module("./declarative-marketplace-sources-section", () => ({
  DeclarativeMarketplaceSources: ({ onChanged }: { onChanged?: () => void }) =>
    <button onClick={onChanged}>Change source fixture</button>,
}));
// The management page owns invalidation and parent refresh. Catalog browsing,
// review lifecycle and native adapters have their own isolated suites.
mock.module("./marketplace/marketplace-section", () => ({
  DeclarativeMarketplaceSection: ({ service }: { service: DeclarativeMarketplaceService }) => {
    useEffect(() => {
      marketplaceMounts += 1;
      return () => { marketplaceUnmounts += 1; };
    }, []);
    return <button onClick={() => void service.confirm("market-review", "market-digest", true)}>Marketplace install fixture</button>;
  },
}));
mock.module("./declarative-plugin-settings-editor", () => ({ DeclarativePluginSettingsEditor: () => null }));
mock.module("./declarative-plugin-launch", () => ({
  rescanDeclarativePlugins: () => call("rescan"),
  listDeclarativePlugins: () => call("list"),
  listDeclarativeWebWindows: () => call("windows"),
  closeDeclarativeWebWindow: () => call("close"),
  openDeclarativeWebWindow: () => call("open"),
  prepareDeclarativeDiskInstall: (sourcePath: string) => call("prepare", { sourcePath }),
  confirmDeclarativeDiskInstall: (sessionId: string, manifestDigest: string) => call("confirm", { sessionId, manifestDigest }),
  cancelDeclarativeDiskInstall: (sessionId: string) => call("cancel", { sessionId }),
  setDeclarativePluginEnabled: (pluginId: string, enabled: boolean) => call("enabled", { pluginId, enabled }),
  rollbackDeclarativePlugin: (pluginId: string) => call("rollback", { pluginId }),
  uninstallDeclarativePlugin: (pluginId: string) => call("uninstall", { pluginId }),
}));

const { createRoot } = await import("react-dom/client");
const { LocaleProvider } = await import("@/i18n/locale-provider");
const { createTranslator } = await import("@/i18n/locale");
const { DeclarativePluginsSection } = await import("./declarative-plugins-section");
type Language = "en-US" | "zh-CN";
let host: HTMLDivElement;
let root: Root | null = null;
let language: Language = "en-US";
const cleanupGates: Array<() => void> = [];
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
environment.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => {
  if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
  else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

beforeEach(() => {
  language = "en-US";
  intercept = () => undefined;
  calls.length = 0;
  marketplaceMounts = 0;
  marketplaceUnmounts = 0;
  catalog = [
    summary("io.example.alpha", { displayName: "Alpha", languages: [{ id: "demo", displayName: "Demo", fileExtensions: [".demo"], fileNames: [] }] }),
    summary("io.example.beta", { displayName: "Beta", enabled: false }),
    summary("io.example.bundled", { displayName: "Bundled fixture", source: "bundled" }),
    summary("io.example.bad", { displayName: "Bad fixture", status: "rejected", enabled: false, rejection: { code: "fixture.rejected", message: "untrusted fixture", path: null } }),
  ];
  workspace.setState({ projectTabs: [{ path: "C:/fixtures/one", isActive: true }] });
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  try {
    await act(async () => root?.unmount());
    root = null;
    await act(async () => { cleanupGates.splice(0).forEach((release) => release()); });
  } finally {
    host.remove();
  }
});

function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((accept, decline) => { resolve = accept; reject = decline; });
  cleanupGates.push(() => resolve(fallback));
  return { promise, resolve, reject };
}

async function mount(strict = false) {
  const content = (
    <LocaleProvider language={language}>
      <DeclarativePluginsSection />
    </LocaleProvider>
  );
  await act(async () => root?.render(strict ? <StrictMode>{content}</StrictMode> : content));
}
const text = (key: string) => createTranslator(language)(key);
function button(label: string, parent: ParentNode = host) {
  const found = [...parent.querySelectorAll<HTMLButtonElement>("button")].find((element) => element.textContent?.trim() === label);
  if (!found) throw new Error(`button not found: ${label}`);
  return found;
}
async function click(label: string, parent: ParentNode = host) {
  await act(async () => button(label, parent).click());
}
function row(id: string) {
  return host.querySelector<HTMLButtonElement>(`[data-plugin-id="${id}"] button`)!;
}
async function select(id: string) { await act(async () => row(id).click()); }
async function search(value: string) {
  await act(async () => {
    const input = host.querySelector<HTMLInputElement>("input")!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
  });
}

test("search and filters preserve selection and the active detail tab without N+1 detail loads", async () => {
  await mount();
  expect(calls.filter((call) => call.command === "declarative_plugins_details")).toHaveLength(0);
  await select("io.example.alpha");
  const tabs = [...host.querySelectorAll<HTMLButtonElement>('[role="tab"]')];
  expect(tabs).toHaveLength(5);
  await act(async () => tabs[4]!.click());
  await search("no match");
  expect(host.textContent).toContain(text("settings.declarativePluginList.selectionHidden"));
  expect(host.querySelector('[role="tabpanel"]')).not.toBeNull();
  expect(tabs[4]!.getAttribute("aria-selected")).toBe("true");
  await click(text("settings.declarativePluginList.showSelection"));
  expect(row("io.example.alpha").getAttribute("aria-pressed")).toBe("true");
  await search("/");
  expect(host.querySelector<HTMLInputElement>("input")!.value).toBe("");
  await click(text("settings.declarativePluginList.state.disabled"));
  expect(row("io.example.alpha")).toBeNull();
  expect(row("io.example.beta")).not.toBeNull();
  expect(calls.filter((call) => call.command === "declarative_plugins_details")).toHaveLength(1);
  expect(host.textContent).toContain(text("settings.declarativePluginList.unavailableFilters"));
});

test.each(["en-US", "zh-CN"] as const)("%s renders truthful grouping, ID search and keyboard selection with shared controls", async (locale) => {
  language = locale;
  await mount();
  expect(host.textContent).toContain(text("settings.declarativePluginList.state.quarantined"));
  expect(host.textContent).toContain(text("settings.declarativePlugins.source.installed"));
  expect(host.textContent).not.toContain("official");
  await search("EXAMPLE.ALPHA");
  expect(host.querySelectorAll("[data-plugin-id]")).toHaveLength(1);
  await search("");
  await act(async () => {
    const first = row("io.example.alpha");
    first.focus();
    first.dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true }));
  });
  expect(document.activeElement).toBe(row("io.example.bad"));
  expect(row("io.example.bad").getAttribute("aria-pressed")).toBe("true");
});

test.each([
  ["enabled", "settings.declarativePluginDetails.action.disable"],
  ["uninstall", "settings.declarativePluginDetails.action.uninstall"],
  ["rollback", "settings.declarativePluginDetails.action.rollback"],
] as const)("%s failure is retryable and only a successful uninstall clears selection", async (command, label) => {
  let failures = 1;
  intercept = (name) => name === command && failures-- > 0 ? Promise.reject(new Error("action fixture failed")) : undefined;
  await mount();
  await select("io.example.alpha");
  await click(text(label));
  expect(host.textContent).toContain("action fixture failed");
  expect(row("io.example.alpha").getAttribute("aria-pressed")).toBe("true");
  await click(text(label));
  expect(calls.filter((call) => call.command === command)).toHaveLength(2);
  expect(host.textContent).not.toContain("action fixture failed");
  if (command === "uninstall") {
    expect(row("io.example.alpha")).toBeNull();
    expect(host.textContent).toContain(text("settings.declarativePluginDetails.noSelection"));
  } else {
    expect(row("io.example.alpha").getAttribute("aria-pressed")).toBe("true");
    expect(host.querySelectorAll('[role="tab"]')).toHaveLength(5);
  }
});

test("refresh does not recreate the selected detail panel and load errors can be retried", async () => {
  await mount();
  await select("io.example.alpha");
  const versions = host.querySelectorAll<HTMLButtonElement>('[role="tab"]')[4]!;
  await act(async () => versions.click());
  intercept = (command) => command === "list" ? Promise.reject(new Error("catalog unavailable")) : undefined;
  await click(text("settings.declarativePluginList.refresh"));
  expect(host.textContent).toContain("catalog unavailable");
  expect(row("io.example.alpha").getAttribute("aria-pressed")).toBe("true");
  intercept = () => undefined;
  await click(text("settings.declarativePluginList.refresh"));
  expect(host.textContent).not.toContain("catalog unavailable");
  expect(versions.isConnected).toBe(true);
  expect(versions.getAttribute("aria-selected")).toBe("true");
  expect(calls.filter((call) => call.command === "declarative_plugins_details")).toHaveLength(1);
});

test("late detail success and failure cannot cross plugin or workspace selections", async () => {
  const oldPlugin = deferred(detail(catalog[0]!));
  const oldWorkspace = deferred(detail(catalog[1]!));
  let loads = 0;
  intercept = (command) => {
    if (command !== "declarative_plugins_details") return;
    loads += 1;
    if (loads === 1) return oldPlugin.promise;
    if (loads === 2) return oldWorkspace.promise;
  };
  await mount();
  await select("io.example.alpha");
  await select("io.example.beta");
  await act(async () => workspace.setState({ projectTabs: [{ path: "C:/fixtures/two", isActive: true }] }));
  expect(host.querySelectorAll('[role="tab"]')).toHaveLength(5);
  await act(async () => {
    oldPlugin.reject(new Error("stale plugin failure"));
    oldWorkspace.resolve({ ...detail(catalog[1]!), displayName: "stale workspace success" });
  });
  expect(host.textContent).not.toContain("stale plugin failure");
  expect(host.textContent).not.toContain("stale workspace success");
  expect(row("io.example.beta").getAttribute("aria-pressed")).toBe("true");
});

test("an externally changed summary refreshes details without losing selection", async () => {
  await mount();
  await select("io.example.alpha");
  catalog[0]!.enabled = false;
  await click(text("settings.declarativePluginList.refresh"));
  expect(row("io.example.alpha").getAttribute("aria-pressed")).toBe("true");
  expect(button(text("settings.declarativePluginDetails.action.enable")).disabled).toBe(false);
  expect(calls.filter((call) => call.command === "declarative_plugins_details")).toHaveLength(2);
});

test("a late refresh from the StrictMode mount cannot overwrite the active catalog", async () => {
  const oldScan = deferred(0);
  let scans = 0;
  intercept = (command) => command === "rescan" && ++scans === 1 ? oldScan.promise : undefined;
  await mount(true);
  expect(host.querySelectorAll("[data-plugin-id]")).toHaveLength(4);
  catalog = [];
  await act(async () => oldScan.resolve(0));
  expect(host.querySelectorAll("[data-plugin-id]")).toHaveLength(4);
  expect(calls.filter((call) => call.command === "list")).toHaveLength(1);
});

test("late management failure cannot replace another plugin or workspace", async () => {
  const disabling = deferred(undefined);
  intercept = (command) => command === "enabled" ? disabling.promise : undefined;
  await mount();
  await select("io.example.alpha");
  await click(text("settings.declarativePluginDetails.action.disable"));
  await select("io.example.beta");
  await act(async () => workspace.setState({ projectTabs: [{ path: "C:/fixtures/two", isActive: true }] }));
  await act(async () => disabling.reject(new Error("old operation failed")));
  expect(host.textContent).not.toContain("old operation failed");
  expect(row("io.example.beta").getAttribute("aria-pressed")).toBe("true");
  expect(button(text("settings.declarativePluginDetails.action.enable")).disabled).toBe(false);
});

test("a prepared import arriving after unmount is cancelled exactly once", async () => {
  const preparing = deferred(review);
  intercept = (command) => command === "prepare" ? preparing.promise : undefined;
  await mount();
  await click(text("settings.declarativePlugins.import"));
  expect(calls.filter((call) => call.command === "prepare")).toHaveLength(1);
  await act(async () => root?.unmount());
  root = null;
  await act(async () => preparing.resolve(review));
  expect(calls.filter((call) => call.command === "cancel")).toEqual([{ command: "cancel", args: { sessionId: review.sessionId } }]);
});

test("closing during approval cancels the pending review and ignores late confirmation", async () => {
  const confirming = deferred(catalog[0]);
  intercept = (command) => command === "confirm" ? confirming.promise : undefined;
  await mount();
  await click(text("settings.declarativePlugins.import"));
  await click(text("settings.declarativePlugins.confirmInstall"));
  expect(calls.filter((call) => call.command === "confirm")).toHaveLength(1);
  const scans = calls.filter((call) => call.command === "rescan").length;
  await act(async () => root?.unmount());
  root = null;
  await act(async () => confirming.resolve(catalog[0]));
  expect(calls.filter((call) => call.command === "cancel")).toHaveLength(1);
  expect(calls.filter((call) => call.command === "rescan")).toHaveLength(scans);
});

test("failed approval releases its review and import can be retried", async () => {
  intercept = (command) => command === "confirm" ? Promise.reject(new Error("approval unavailable")) : undefined;
  await mount();
  await click(text("settings.declarativePlugins.import"));
  await click(text("settings.declarativePlugins.confirmInstall"));
  expect(host.textContent).toContain("approval unavailable");
  expect(host.querySelector('[role="dialog"]')).toBeNull();
  expect(calls.filter((call) => call.command === "cancel")).toHaveLength(1);
  await click(text("settings.declarativePlugins.import"));
  expect(host.querySelector('[role="dialog"]')).not.toBeNull();
  expect(calls.filter((call) => call.command === "prepare")).toHaveLength(2);
});

test("a source change replaces the marketplace owner without rescanning unrelated installed packages", async () => {
  await mount();
  const scans = calls.filter((call) => call.command === "rescan").length;
  expect(marketplaceMounts).toBe(1);
  await click("Change source fixture");
  expect(marketplaceMounts).toBe(2);
  expect(marketplaceUnmounts).toBe(1);
  expect(calls.filter((call) => call.command === "rescan")).toHaveLength(scans);
});

test("a completed disk install invalidates marketplace ownership and refreshes the installed catalog", async () => {
  intercept = (command) => {
    if (command !== "confirm") return;
    const imported = summary("io.example.import");
    catalog.push(imported);
    return Promise.resolve(imported);
  };
  await mount();
  await click(text("settings.declarativePlugins.import"));
  expect(marketplaceMounts).toBe(1);
  await click(text("settings.declarativePlugins.confirmInstall"));
  expect(row("io.example.import")).not.toBeNull();
  expect(marketplaceMounts).toBe(2);
  expect(marketplaceUnmounts).toBe(1);
});

test("a cancelled or failed disk approval does not invalidate the marketplace as though a package was installed", async () => {
  await mount();
  await click(text("settings.declarativePlugins.import"));
  await click(text("ui.cancel"), host.querySelector('[role="dialog"]')!);
  expect(marketplaceMounts).toBe(1);
  intercept = (command) => command === "confirm" ? Promise.reject(new Error("approval unavailable")) : undefined;
  await click(text("settings.declarativePlugins.import"));
  await click(text("settings.declarativePlugins.confirmInstall"));
  expect(marketplaceMounts).toBe(1);
  expect(marketplaceUnmounts).toBe(0);
});

test("native marketplace confirmation refreshes the installed parent only after commit completes", async () => {
  const confirming = deferred(catalog[0]);
  intercept = (command) => command === "declarative_marketplace_confirm" ? confirming.promise : undefined;
  await mount();
  const scans = calls.filter((call) => call.command === "rescan").length;
  await click("Marketplace install fixture");
  expect(calls.filter((call) => call.command === "rescan")).toHaveLength(scans);
  catalog.push(summary("io.example.from-market"));
  expect(row("io.example.from-market")).toBeNull();
  await act(async () => confirming.resolve(catalog[0]));
  expect(row("io.example.from-market")).not.toBeNull();
  expect(calls.filter((call) => call.command === "rescan")).toHaveLength(scans + 1);
  expect(calls.find((call) => call.command === "declarative_marketplace_confirm")?.args).toEqual({
    operationId: "market-review", manifestDigest: "market-digest", approved: true,
  });
  expect(marketplaceMounts).toBe(1);
});
