import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { PluginDetailsModel } from "./plugin-details.types";

mock.module("@/platform/tauri-core", () => ({ invoke: mock() }));
mock.module("../declarative-plugin-launch", () => ({
  rollbackDeclarativePlugin: mock(),
  setDeclarativePluginEnabled: mock(),
  uninstallDeclarativePlugin: mock(),
}));

mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({
    language: "en-US",
    t: (key: string, values?: Record<string, string | number>) =>
      values?.index ? `${key} ${values.index}` : key,
  }),
}));
mock.module("../declarative-plugin-settings-editor", () => ({
  DeclarativePluginSettingsEditor: ({ pluginId }: { pluginId: string }) => (
    <div data-testid="shared-settings-editor">shared settings for {pluginId}</div>
  ),
}));

const { PluginDetailsPanel, PluginDetailsView } = await import("./plugin-details-view");

let restoreDom: (() => void) | null = null;
let root: Root | null = null;
let host: HTMLDivElement | null = null;

beforeEach(() => {
  restoreDom = installHappyDom();
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  if (root) await act(async () => root?.unmount());
  host?.remove();
  restoreDom?.();
  root = null;
  host = null;
  restoreDom = null;
});

function details(): PluginDetailsModel {
  return {
    identity: { pluginId: "io.example.complete", source: "installed", version: "2.0.0" },
    displayName: "Complete Plugin",
    vendorName: "Example",
    description: "Default description",
    localizedDescriptions: { "en-US": "Localized description" },
    apiVersion: 1,
    enabled: true,
    status: "accepted",
    rejection: null,
    settings: [{ id: "heap", type: "integer", title: "Heap", default: 512 }],
    primaryLanguageId: "demo",
    features: [{ kind: "languageServer", subject: "demo", title: "Demo", availability: "available", detail: { launchKind: "packaged" } }],
    permissions: ["languageServer.launch"],
    programs: [{ kind: "packagedLanguageServer", arguments: ["bin/server", "--stdio"], validationArguments: ["--version"], initializationOptions: { trace: true } }],
    versions: {
      current: {
        version: "2.0.0",
        origin: "community",
        channel: "disk",
        sourceId: null,
        sourceName: null,
        repository: null,
        fileName: "complete.zip",
        archiveSha256: "archive",
        contentDigest: "content",
        verification: { status: "approvedDigest", keyId: null },
      },
      previous: {
        version: "1.0.0",
        origin: "marketplace",
        channel: "marketplace",
        sourceId: "store",
        sourceName: "Store",
        repository: "https://example.invalid",
        fileName: null,
        archiveSha256: "old-archive",
        contentDigest: "old-content",
        verification: { status: "unknown", keyId: null },
      },
      updateStatus: "unknown",
    },
    operations: { canSetEnabled: true, canUninstall: true, canRollback: true },
  };
}

async function renderView() {
  await act(async () => {
    root?.render(
      <PluginDetailsView
        details={details()}
        workspacePath="C:/work"
        operation={null}
        operationError={null}
        onOperation={() => {}}
      />,
    );
  });
}

test("renders five keyboard tabs and complete program declarations", async () => {
  await renderView();
  const tabs = [...host!.querySelectorAll<HTMLButtonElement>('[role="tab"]')];
  expect(tabs).toHaveLength(5);
  await act(async () => tabs[3]!.click());
  expect(host!.querySelector('[role="tabpanel"]')?.getAttribute("aria-labelledby")).toBe(tabs[3]!.id);
  expect(host!.textContent).toContain("languageServer.launch");
  expect(host!.textContent).toContain("bin/server");
  expect(host!.textContent).toContain("validationArguments");
  expect(host!.textContent).toContain("initializationOptions");

  await act(async () => {
    tabs[3]!.focus();
    tabs[3]!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  expect(tabs[4]!.getAttribute("aria-selected")).toBe("true");
  expect(host!.textContent).toContain("Store");
  expect(host!.textContent).toContain("settings.declarativePluginDetails.update.unknown");
});

test("the settings tab reuses the shared settings editor", async () => {
  await renderView();
  const tabs = [...host!.querySelectorAll<HTMLButtonElement>('[role="tab"]')];
  await act(async () => tabs[2]!.click());
  expect(host!.querySelector('[data-testid="plugin-details-settings-editor"]')).not.toBeNull();
  expect(host!.querySelector('[data-testid="shared-settings-editor"]')?.textContent).toContain("io.example.complete");
});

test("no current selection has a stable empty state and never invokes the service", async () => {
  const service = {
    load: mock(async () => details()),
    setEnabled: mock(async () => {}),
    uninstall: mock(async () => {}),
    rollback: mock(async () => {}),
  };
  await act(async () => root?.render(
    <PluginDetailsPanel selection={null} workspacePath={null} service={service} />,
  ));
  expect(host!.textContent).toContain("settings.declarativePluginDetails.noSelection");
  expect(service.load).not.toHaveBeenCalled();
});

test("StrictMode effect replay creates a live detail session", async () => {
  const service = {
    load: mock(async () => details()),
    setEnabled: mock(async () => {}),
    uninstall: mock(async () => {}),
    rollback: mock(async () => {}),
  };
  await act(async () => root?.render(
    <StrictMode>
      <PluginDetailsPanel
        selection={{ pluginId: "io.example.complete", source: "installed" }}
        workspacePath="C:/work"
        service={service}
      />
    </StrictMode>,
  ));
  expect(host!.textContent).toContain("Complete Plugin");
  expect(host!.querySelectorAll('[role="tab"]')).toHaveLength(5);
});
