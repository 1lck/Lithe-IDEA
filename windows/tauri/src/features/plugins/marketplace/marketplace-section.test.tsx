import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type {
  DeclarativeMarketplaceService,
  MarketplaceIndex,
  MarketplaceIndexEntry,
  MarketplaceInstalledPlugin,
  MarketplaceInstalledProvider,
  MarketplaceReview,
  MarketplaceSourceIndex,
} from "./marketplace-types";

const restoreDom = installHappyDom();
afterAll(restoreDom);
// Load browser-dependent modules after installing DOM globals, exactly like
// the declarative-marketplace-sources test: react-dom and the component
// observe happy-dom, while react and LocaleProvider stay static.
const { createRoot } = await import("react-dom/client");
const { DeclarativeMarketplaceSection: Section } = await import("./marketplace-section");

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function settle(rounds = 8): Promise<void> {
  for (let round = 0; round < rounds; round += 1) {
    await act(async () => {
      await Promise.resolve();
    });
  }
}

function availableEntry(
  pluginId: string,
  overrides: Partial<MarketplaceIndexEntry> = {},
): MarketplaceIndexEntry {
  const version = overrides.latestVersion ?? "1.0.0";
  return {
    id: pluginId,
    name: `Plugin ${pluginId}`,
    author: "example",
    repository: `https://github.com/example/${pluginId}`,
    homepage: null,
    description: `${pluginId} description`,
    localizedDescriptions: {},
    tags: [],
    license: "MIT",
    icon: null,
    platforms: ["windows-x64"],
    latestVersion: version,
    latestReleaseDate: "2026-01-01",
    availability: {
      status: "available",
      version,
      pluginAPIVersion: 1,
      releaseDate: "2026-01-01",
      downloadURL: `https://github.com/example/${pluginId}/releases/download/v${version}/${pluginId}.zip`,
      sha256: "c".repeat(64),
    },
    ...overrides,
  };
}

/** An available entry whose newest installable version is `version`. */
function entryWithVersion(pluginId: string, version: string): MarketplaceIndexEntry {
  return availableEntry(pluginId, {
    latestVersion: version,
    availability: {
      status: "available",
      version,
      pluginAPIVersion: 1,
      releaseDate: "2026-01-01",
      downloadURL: `https://github.com/example/${pluginId}/releases/download/v${version}/${pluginId}.zip`,
      sha256: "c".repeat(64),
    },
  });
}

const officialCatalog: MarketplaceSourceIndex[] = [
  {
    sourceId: "lithe-official",
    sourceName: "Lithe",
    index: {
      plugins: [
        availableEntry("io.example.alpha"),
        availableEntry("io.example.shared"),
        availableEntry("io.example.disk-managed"),
        availableEntry("io.example.other-source"),
        availableEntry("io.example.no-windows", {
          availability: {
            status: "unsupported",
            code: "plugin.index.platformUnsupported",
            platform: "windows-x64",
            message: "This plugin is not available for windows-x64.",
          },
        }),
        entryWithVersion("io.example.update", "2.0.0"),
      ],
      rejected: [
        { id: "io.example.broken", error: { code: "plugin.index.invalid", message: "bad", path: null } },
      ],
    },
    problem: null,
  },
  {
    sourceId: "source-store",
    sourceName: "Lithe Store",
    index: {
      plugins: [availableEntry("io.example.shared"), availableEntry("io.example.other-source")],
      rejected: [],
    },
    problem: null,
  },
];

function installedFixture(): MarketplaceInstalledPlugin[] {
  return [
    // Update available from the official listing of the same source.
    {
      pluginId: "io.example.update",
      version: "1.0.0",
      channel: { kind: "marketplace", sourceId: "lithe-official", sourceName: "Lithe" },
    },
    // Installed from Lithe Store; the official listing must not take over.
    {
      pluginId: "io.example.other-source",
      version: "1.0.0",
      channel: { kind: "marketplace", sourceId: "source-store", sourceName: "Lithe Store" },
    },
    // Disk import with the same ID as a marketplace entry.
    {
      pluginId: "io.example.disk-managed",
      version: "1.0.0",
      channel: { kind: "disk" },
    },
  ];
}

function reviewFixture(overrides: Partial<MarketplaceReview> = {}): MarketplaceReview {
  return {
    operationId: "op-1",
    sourceId: "lithe-official",
    sourceName: "Lithe",
    indexUrl: "https://example.com/index.json",
    officialPublisherVerified: false,
    requiresConfirmation: true,
    prepared: {
      sessionId: "session-1",
      manifestDigest: "digest-1",
      displayName: "Plugin io.example.alpha",
      review: {
        pluginId: "io.example.alpha",
        version: "1.0.0",
        permissions: ["process.launch", "fs.read"],
        programs: [{ command: "run-server", args: ["--port", "8080"] }],
        newPrograms: [{ command: "run-server", args: ["--port", "8080"] }],
      },
    },
    ...overrides,
  };
}

const consoleErrorSpy = spyOn(console, "error").mockImplementation(() => {});
afterEach(() => consoleErrorSpy.mockClear());
afterAll(() => consoleErrorSpy.mockRestore());

interface MountOptions {
  catalog?: Promise<MarketplaceSourceIndex[]>;
  installed?: MarketplaceInstalledProvider;
  language?: "en-US" | "zh-CN";
}

async function mountSection(options: MountOptions = {}): Promise<{
  host: HTMLDivElement;
  unmount: () => Promise<void>;
  service: ScriptedService;
}> {
  const service = new ScriptedService(options.catalog);
  const installed = options.installed ?? (() => Promise.resolve(installedFixture()));
  const host = document.createElement("div");
  document.body.append(host);
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const root: Root = createRoot(host);
  await act(async () => {
    root.render(
      <LocaleProvider language={options.language ?? "en-US"}>
        <Section service={service} installed={installed} />
      </LocaleProvider>,
    );
  });
  const unmount = async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  };
  return { host, unmount, service };
}

class ScriptedService implements DeclarativeMarketplaceService {
  readonly listCalls: Array<ReturnType<typeof deferred<MarketplaceSourceIndex[]>>> = [];
  readonly refreshCalls: Array<{
    operationId: string;
    sourceId: string;
    deferred: ReturnType<typeof deferred<MarketplaceIndex>>;
  }> = [];
  readonly prepareCalls: Array<{
    operationId: string;
    sourceId: string;
    pluginId: string;
    deferred: ReturnType<typeof deferred<MarketplaceReview>>;
  }> = [];
  readonly confirmCalls: Array<{
    operationId: string;
    manifestDigest: string;
    approved: boolean;
    deferred: ReturnType<typeof deferred<{ pluginId: string; version: string; enabled: boolean }>>;
  }> = [];
  readonly cancelCalls: string[] = [];

  constructor(private readonly firstCatalog?: Promise<MarketplaceSourceIndex[]>) {}

  list(): Promise<MarketplaceSourceIndex[]> {
    if (this.listCalls.length === 0 && this.firstCatalog) {
      this.listCalls.push({ promise: this.firstCatalog } as never);
      return this.firstCatalog;
    }
    const call = deferred<MarketplaceSourceIndex[]>();
    this.listCalls.push(call);
    return call.promise;
  }

  refresh(operationId: string, sourceId: string): Promise<MarketplaceIndex> {
    const call = deferred<MarketplaceIndex>();
    this.refreshCalls.push({ operationId, sourceId, deferred: call });
    return call.promise;
  }

  prepare(
    operationId: string,
    sourceId: string,
    pluginId: string,
  ): Promise<MarketplaceReview> {
    const call = deferred<MarketplaceReview>();
    this.prepareCalls.push({ operationId, sourceId, pluginId, deferred: call });
    return call.promise;
  }

  confirm(
    operationId: string,
    manifestDigest: string,
    approved: boolean,
  ): Promise<{ pluginId: string; version: string; enabled: boolean }> {
    const call = deferred<{ pluginId: string; version: string; enabled: boolean }>();
    this.confirmCalls.push({ operationId, manifestDigest, approved, deferred: call });
    return call.promise;
  }

  cancel(operationId: string): Promise<void> {
    this.cancelCalls.push(operationId);
    return Promise.resolve();
  }
}

function rowOf(host: HTMLDivElement, pluginId: string): HTMLLIElement | null {
  return host.querySelector(`[data-testid="marketplace-plugin-${pluginId}"]`);
}

function rowText(host: HTMLDivElement, pluginId: string): string {
  return rowOf(host, pluginId)?.textContent ?? "";
}

// The cached catalog renders every install state truthfully: installable,
// update from the recorded source only, cross-source, disk-managed, and the
// platform-missing entry with its reason and no install button.
test("the catalog renders rows with accurate install states", async () => {
  const { host, unmount } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
  });
  await settle();
  try {
    expect(rowOf(host, "io.example.alpha")).not.toBeNull();
    expect(
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]'),
    ).not.toBeNull();

    // Same source, newer listing: the row offers an update through it.
    expect(rowText(host, "io.example.update")).toContain("Update available: 1.0.0 → 2.0.0");
    expect(
      host.querySelector<HTMLButtonElement>(
        '[data-testid="marketplace-install-io.example.update"]',
      )?.textContent,
    ).toBe("Update");

    // Recorded install source keeps the plugin: its offer is the one shown in
    // the all-sources view, so the row reports a plain installed state.
    expect(rowText(host, "io.example.other-source")).toContain("· Lithe Store");
    expect(rowText(host, "io.example.other-source")).toContain("Installed 1.0.0");
    expect(
      host.querySelector('[data-testid="marketplace-install-io.example.other-source"]'),
    ).toBeNull();

    // A disk import is never taken over by a same-ID marketplace entry.
    expect(rowText(host, "io.example.disk-managed")).toContain(
      "Installed from disk or bundled; not managed by the marketplace.",
    );
    expect(
      host.querySelector('[data-testid="marketplace-install-io.example.disk-managed"]'),
    ).toBeNull();

    // A missing Windows artifact states the reason and offers no install.
    expect(rowText(host, "io.example.no-windows")).toContain("No build for windows-x64.");
    expect(
      host.querySelector('[data-testid="marketplace-install-io.example.no-windows"]'),
    ).toBeNull();

    // The shared plugin shows the recorded-source offer in the all-sources view.
    expect(rowText(host, "io.example.shared")).toContain("Lithe");
    expect(host.querySelectorAll('[data-testid^="marketplace-plugin-"]').length).toBe(6);
    expect(consoleErrorSpy).not.toHaveBeenCalled();
  } finally {
    await unmount();
  }
});

test("a failed first load shows the error and a retry recovers the catalog", async () => {
  const first = deferred<MarketplaceSourceIndex[]>();
  const { host, unmount, service } = await mountSection({ catalog: first.promise });
  await settle();
  try {
    expect(host.textContent).toContain("Loading the marketplace");
    await act(async () => first.reject(new Error("ipc offline")));
    await settle();
    expect(host.textContent).toContain("The marketplace could not be loaded. (ipc offline)");
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-retry-load"]')!.click();
    });
    service.listCalls[1]!.resolve(officialCatalog);
    await settle();
    expect(rowOf(host, "io.example.alpha")).not.toBeNull();
    expect(service.cancelCalls).toEqual([]);
  } finally {
    await unmount();
  }
});

test("search narrows the catalog and switching the source cancels owned operations", async () => {
  const { host, unmount, service } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
  });
  await settle();
  try {
    const search = host.querySelector<HTMLInputElement>('[data-testid="marketplace-search-input"]')!;
    const setValue = (value: string) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(search, value);
      search.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
    };
    await act(async () => setValue("alpha"));
    expect(host.querySelectorAll('[data-testid^="marketplace-plugin-"]').length).toBe(1);
    expect(rowOf(host, "io.example.alpha")).not.toBeNull();
    // Localized descriptions participate in matching.
    await act(async () => setValue(""));
    expect(host.querySelectorAll('[data-testid^="marketplace-plugin-"]').length).toBe(6);

    // Start a download, then leave its source context: the page cancels it.
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
    expect(rowText(host, "io.example.alpha")).toContain("Preparing the package");
    const select = host.querySelector<HTMLSelectElement>('[data-testid="marketplace-source-select"]')!;
    await act(async () => {
      select.value = "source-store";
      select.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(service.cancelCalls.length).toBe(1);
    // The store scope hides official-only rows.
    expect(rowOf(host, "io.example.alpha")).toBeNull();
    expect(rowOf(host, "io.example.shared")).not.toBeNull();

    // Filtering back to the official source surfaces the fixed-source rule:
    // the shared-ID plugin installed from Lithe Store is not takeable there.
    await act(async () => {
      select.value = "lithe-official";
      select.dispatchEvent(new window.Event("change", { bubbles: true }));
    });
    expect(rowText(host, "io.example.other-source")).toContain(
      "Installed from Lithe Store; updates come from that source only.",
    );
    expect(
      host.querySelector('[data-testid="marketplace-install-io.example.other-source"]'),
    ).toBeNull();
  } finally {
    await unmount();
  }
});

test("the review card renders the prepared objects and only a verified official badge", async () => {
  const { host, unmount, service } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
  });
  await settle();
  try {
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
    // The scripted review echoes the operation ID the host would return.
    service.prepareCalls[0]!.deferred.resolve(
      reviewFixture({ operationId: service.prepareCalls[0]!.operationId }),
    );
    await settle();
    const card = host.querySelector('[data-testid="marketplace-review-card"]')!;
    expect(card.textContent).toContain("Install Plugin io.example.alpha 1.0.0?");
    expect(card.textContent).toContain("Source: Lithe");
    expect(card.textContent).toContain("https://example.com/index.json");
    expect(card.textContent).toContain("process.launch");
    expect(card.textContent).toContain("fs.read");
    expect(card.textContent).toContain("1 new program(s) need your approval.");
    // An unverified source never shows the official badge.
    expect(host.querySelector('[data-testid="marketplace-official-badge"]')).toBeNull();
    expect(card.textContent).toContain("not verified by Lithe");
    // The full program JSON is available behind the toggle.
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-review-programs-toggle"]')!
        .click();
    });
    expect(card.textContent).toContain("run-server");

    // Rejecting the review discards the prepared snapshot.
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-review-cancel"]')!.click();
    });
    expect(host.querySelector('[data-testid="marketplace-review-card"]')).toBeNull();
    expect(service.cancelCalls).toEqual([service.prepareCalls[0]!.operationId]);

    // A backend-verified review is the only path to the official badge.
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
    const verifiedOperationId = service.prepareCalls[1]!.operationId;
    service.prepareCalls[1]!.deferred.resolve(
      reviewFixture({ operationId: verifiedOperationId, officialPublisherVerified: true }),
    );
    await settle();
    expect(host.querySelector('[data-testid="marketplace-official-badge"]')).not.toBeNull();
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-review-cancel"]')!.click();
    });
    expect(service.cancelCalls).toEqual([
      service.prepareCalls[0]!.operationId,
      verifiedOperationId,
    ]);
  } finally {
    await unmount();
  }
});

test("confirming installs through the prepared digest and reflects the installed state", async () => {
  const { host, unmount, service } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
  });
  await settle();
  try {
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
    service.prepareCalls[0]!.deferred.resolve(
      reviewFixture({ operationId: service.prepareCalls[0]!.operationId }),
    );
    await settle();
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-review-confirm"]')!.click();
    });
    expect(service.confirmCalls[0]).toMatchObject({
      operationId: service.prepareCalls[0]!.operationId,
      manifestDigest: "digest-1",
      approved: true,
    });
    service.confirmCalls[0]!.deferred.resolve({
      pluginId: "io.example.alpha",
      version: "1.0.0",
      enabled: true,
    });
    await settle();
    expect(host.querySelector('[data-testid="marketplace-review-card"]')).toBeNull();
    expect(rowText(host, "io.example.alpha")).toContain("Installed 1.0.0");
    expect(
      host.querySelector('[data-testid="marketplace-install-io.example.alpha"]'),
    ).toBeNull();
  } finally {
    await unmount();
  }
});

test("a download can be cancelled from the row and unmount releases owned operations", async () => {
  const { host, unmount, service } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
  });
  await settle();
  try {
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
    const row = rowOf(host, "io.example.alpha")!;
    const cancelButton = [...row.querySelectorAll("button")].find(
      (button) => button.textContent === "Cancel",
    )!;
    await act(async () => cancelButton.click());
    expect(service.cancelCalls).toEqual([service.prepareCalls[0]!.operationId]);

    // A second download is released again when the page unmounts.
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-testid="marketplace-install-io.example.alpha"]')!
        .click();
    });
  } finally {
    await unmount();
  }
  expect(service.cancelCalls).toEqual([
    service.prepareCalls[0]!.operationId,
    service.prepareCalls[1]!.operationId,
  ]);
  // A late prepare after unmount never reopens a review.
  service.prepareCalls[1]!.deferred.resolve(reviewFixture());
  await settle();
});

test("missing backend bindings render the explicit not-connected notice", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <Section />
      </LocaleProvider>,
    );
  });
  try {
    expect(host.querySelector('[data-testid="marketplace-not-connected"]')).not.toBeNull();
    expect(host.textContent).toContain("The marketplace backend is not connected in this build.");
  } finally {
    await act(async () => root.unmount());
    host.remove();
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

test("source problems and ignored entries surface per source with a retry", async () => {
  const catalog: MarketplaceSourceIndex[] = [
    {
      sourceId: "lithe-official",
      sourceName: "Lithe",
      index: null,
      problem: "cache bytes corrupted",
    },
  ];
  const { host, unmount, service } = await mountSection({
    catalog: Promise.resolve(catalog),
    installed: () => Promise.resolve([]),
  });
  await settle();
  try {
    const status = host.querySelector('[data-testid="marketplace-source-status-lithe-official"]')!;
    expect(status.textContent).toContain("The cached index could not be read. (cache bytes corrupted)");
    await act(async () => {
      host.querySelector<HTMLButtonElement>(
        '[data-testid="marketplace-source-retry-lithe-official"]',
      )!.click();
    });
    expect(service.refreshCalls).toHaveLength(1);
    expect(service.refreshCalls[0]!.sourceId).toBe("lithe-official");
    service.refreshCalls[0]!.deferred.resolve({
      plugins: [availableEntry("io.example.alpha")],
      rejected: [
        { id: "io.example.broken", error: { code: "plugin.index.invalid", message: "bad", path: null } },
      ],
    });
    await settle();
    expect(rowOf(host, "io.example.alpha")).not.toBeNull();
    expect(host.textContent).toContain("Ignored 1 invalid entries.");
  } finally {
    await unmount();
  }
});

test("the zh-Hans locale renders the Chinese catalog strings", async () => {
  const { host, unmount } = await mountSection({
    catalog: Promise.resolve(officialCatalog),
    language: "zh-CN",
  });
  await settle();
  try {
    expect(host.textContent).toContain("插件市场");
    expect(rowText(host, "io.example.update")).toContain("有可用更新：1.0.0 → 2.0.0");
    expect(rowText(host, "io.example.disk-managed")).toContain("不由市场管理");
    expect(rowText(host, "io.example.no-windows")).toContain("暂无 windows-x64 平台的安装包");
  } finally {
    await unmount();
  }
});
