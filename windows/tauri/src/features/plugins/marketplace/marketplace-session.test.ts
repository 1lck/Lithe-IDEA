import { describe, expect, test } from "bun:test";
import {
  MarketplaceSession,
  mergeInstalled,
  type MarketplaceSessionState,
} from "./marketplace-session";
import { marketplaceInstallState, type DeclarativeMarketplaceService } from "./marketplace-types";
import {
  type MarketplaceIndex,
  type MarketplaceIndexEntry,
  type MarketplaceInstallation,
  type MarketplaceInstalledPlugin,
  type MarketplaceInstalledProvider,
  type MarketplaceReview,
  type MarketplaceSourceIndex,
} from "./marketplace-types";

/**
 * Every asynchronous boundary below is a deferred the test resolves
 * explicitly; nothing waits on timers, so failures surface as assertion
 * mismatches instead of timeouts.
 */

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Flushes the deterministic microtask chains the session builds. */
async function settle(rounds = 8): Promise<void> {
  for (let round = 0; round < rounds; round += 1) {
    await Promise.resolve();
  }
}

function availableEntry(
  pluginId: string,
  version = "1.0.0",
  availability?: MarketplaceIndexEntry["availability"],
): MarketplaceIndexEntry {
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
    availability: availability ?? {
      status: "available",
      version,
      pluginAPIVersion: 1,
      releaseDate: "2026-01-01",
      downloadURL: `https://github.com/example/${pluginId}/releases/download/v${version}/${pluginId}.zip`,
      sha256: "b".repeat(64),
    },
  };
}

function sourceIndex(
  sourceId: string,
  sourceName: string,
  plugins: MarketplaceIndexEntry[],
  rejected: MarketplaceIndex["rejected"] = [],
): MarketplaceSourceIndex {
  return { sourceId, sourceName, index: { plugins, rejected }, problem: null };
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
        permissions: ["process.launch"],
        programs: [{ command: "run-server" }],
        newPrograms: [{ command: "run-server" }],
      },
    },
    ...overrides,
  };
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
    deferred: ReturnType<typeof deferred<MarketplaceInstallation>>;
  }> = [];
  readonly cancelCalls: string[] = [];

  list(): Promise<MarketplaceSourceIndex[]> {
    const deferredCall = deferred<MarketplaceSourceIndex[]>();
    this.listCalls.push(deferredCall);
    return deferredCall.promise;
  }

  refresh(operationId: string, sourceId: string): Promise<MarketplaceIndex> {
    const deferredCall = deferred<MarketplaceIndex>();
    this.refreshCalls.push({ operationId, sourceId, deferred: deferredCall });
    return deferredCall.promise;
  }

  prepare(operationId: string, sourceId: string, pluginId: string): Promise<MarketplaceReview> {
    const deferredCall = deferred<MarketplaceReview>();
    this.prepareCalls.push({ operationId, sourceId, pluginId, deferred: deferredCall });
    return deferredCall.promise;
  }

  confirm(
    operationId: string,
    manifestDigest: string,
    approved: boolean,
  ): Promise<MarketplaceInstallation> {
    const deferredCall = deferred<MarketplaceInstallation>();
    this.confirmCalls.push({ operationId, manifestDigest, approved, deferred: deferredCall });
    return deferredCall.promise;
  }

  cancel(operationId: string): Promise<void> {
    this.cancelCalls.push(operationId);
    return Promise.resolve();
  }
}

function harness(options?: { installed?: MarketplaceInstalledProvider }) {
  const service = new ScriptedService();
  const states: MarketplaceSessionState[] = [];
  let counter = 0;
  const session = new MarketplaceSession({
    service,
    installed: options?.installed,
    publish: (state) => states.push(state),
    ids: { next: () => `op-${(counter += 1)}` },
    log: () => {},
  });
  return {
    service,
    session,
    states,
    latest: (): MarketplaceSessionState => states[states.length - 1],
    published: () => states.length,
  };
}

const catalog: MarketplaceSourceIndex[] = [
  sourceIndex("lithe-official", "Lithe", [
    availableEntry("io.example.alpha"),
    availableEntry("io.example.shared"),
  ]),
];

describe("MarketplaceSession loads", () => {
  test("a resolved list publishes the cached catalog and the installed snapshot", async () => {
    const installed = deferred<MarketplaceInstalledPlugin[]>();
    const { service, session, latest } = harness({
      installed: () => installed.promise,
    });
    session.start();
    expect(latest().load.phase).toBe("loading");
    service.listCalls[0].resolve(catalog);
    await settle();
    // The catalog is browsable before the installed snapshot resolves; the
    // states it drives arrive when the provider answers.
    expect(latest().load.phase).toBe("ready");
    expect(latest().installedReady).toBe(false);
    installed.resolve([
      {
        pluginId: "io.example.alpha",
        version: "0.9.0",
        channel: { kind: "marketplace", sourceId: "lithe-official", sourceName: "Lithe" },
      },
    ]);
    await settle();
    expect(latest().load.phase).toBe("ready");
    expect(latest().sources).toHaveLength(1);
    expect(latest().indexes["lithe-official"]!.plugins).toHaveLength(2);
    expect(latest().installed).toHaveLength(1);
    expect(latest().installedReady).toBe(true);
    session.dispose();
  });

  test("a failed first load reports failure and a retry recovers", async () => {
    const { service, session, latest } = harness();
    session.start();
    service.listCalls[0].reject(new Error("ipc offline"));
    await settle();
    expect(latest().load).toEqual({ phase: "failed", reason: "ipc offline" });
    session.retryLoad();
    service.listCalls[1].resolve(catalog);
    await settle();
    expect(latest().load.phase).toBe("ready");
    session.dispose();
  });

  test("a late older list response cannot overwrite a newer generation", async () => {
    const { service, session, latest } = harness();
    session.start();
    session.start();
    const second = [sourceIndex("lithe-official", "Lithe", [availableEntry("io.example.second")])];
    service.listCalls[1].resolve(second);
    await settle();
    expect(latest().indexes["lithe-official"]!.plugins[0]!.id).toBe("io.example.second");
    // The first (older) request resolves last and must be dropped entirely.
    service.listCalls[0].resolve(catalog);
    await settle();
    expect(latest().indexes["lithe-official"]!.plugins[0]!.id).toBe("io.example.second");
    session.dispose();
  });

  test("a failed installed read flags the page without inventing installs", async () => {
    const installed = deferred<MarketplaceInstalledPlugin[]>();
    const { service, session, latest } = harness({
      installed: () => installed.promise,
    });
    session.start();
    service.listCalls[0].resolve(catalog);
    installed.reject(new Error("scan failed"));
    await settle();
    expect(latest().installedFailed).toBe(true);
    expect(latest().installed).toEqual([]);
    expect(latest().installedReady).toBe(false);
    session.dispose();
  });
});

describe("MarketplaceSession refreshes", () => {
  test("refreshing a missing index re-reads native provenance and restores same-source updates", async () => {
    const installedReads: Array<ReturnType<typeof deferred<MarketplaceInstalledPlugin[]>>> = [];
    const { service, session, latest } = harness({
      installed: () => {
        const read = deferred<MarketplaceInstalledPlugin[]>();
        installedReads.push(read);
        return read.promise;
      },
    });
    const offer = {
      sourceId: "lithe-official",
      sourceName: "Lithe",
      entry: availableEntry("io.example.alpha", "2.0.0"),
    };
    try {
      session.start();
      service.listCalls[0]!.resolve([
        {
          sourceId: "lithe-official",
          sourceName: "Lithe",
          index: null,
          problem: "cache missing",
        },
      ]);
      installedReads[0]!.resolve([
        {
          pluginId: "io.example.alpha",
          version: "1.0.0",
          channel: { kind: "unknown" },
        },
      ]);
      await settle();
      expect(marketplaceInstallState(offer, latest().installed[0])).toEqual({
        kind: "managedOutsideMarketplace",
        version: "1.0.0",
      });

      session.refresh("lithe-official");
      service.refreshCalls[0]!.deferred.resolve({ plugins: [offer.entry], rejected: [] });
      await settle();
      expect(latest().sources[0]?.problem).toBeNull();
      expect(installedReads).toHaveLength(2);
      installedReads[1]!.resolve([
        {
          pluginId: "io.example.alpha",
          version: "1.0.0",
          channel: { kind: "marketplace", sourceId: "lithe-official", sourceName: "Lithe" },
        },
      ]);
      await settle();
      expect(marketplaceInstallState(offer, latest().installed[0])).toEqual({
        kind: "updateAvailable",
        installed: "1.0.0",
        available: "2.0.0",
      });
    } finally {
      session.dispose();
      for (const read of installedReads) read.resolve([]);
      for (const refresh of service.refreshCalls) {
        refresh.deferred.resolve({ plugins: [], rejected: [] });
      }
      await settle();
    }
  });

  test("a refresh replaces the index and reports ignored entries", async () => {
    const { service, session, latest } = harness();
    session.start();
    service.listCalls[0].resolve([
      sourceIndex("lithe-official", "Lithe", [availableEntry("io.example.alpha")]),
    ]);
    await settle();
    session.refresh("lithe-official");
    expect(latest().sources[0]!.refreshing).toBe(true);
    service.refreshCalls[0]!.deferred.resolve({
      plugins: [availableEntry("io.example.alpha", "2.0.0")],
      rejected: [
        {
          id: "io.example.bad",
          error: { code: "plugin.index.invalid", message: "bad", path: null },
        },
      ],
    });
    await settle();
    expect(latest().sources[0]!.refreshing).toBe(false);
    expect(latest().sources[0]!.rejectedCount).toBe(1);
    expect(latest().indexes["lithe-official"]!.plugins[0]!.id).toBe("io.example.alpha");
    session.dispose();
  });

  test("a failed refresh keeps the cached catalog and records the reason", async () => {
    const { service, session, latest } = harness();
    session.start();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.refresh("lithe-official");
    service.refreshCalls[0]!.deferred.reject(new Error("network unreachable"));
    await settle();
    expect(latest().sources[0]!.refreshError).toBe("network unreachable");
    expect(latest().indexes["lithe-official"]).toBeDefined();
    session.dispose();
  });

  test("refreshing a source releases its reviews because the host epoch moved", async () => {
    const { service, session, latest } = harness();
    session.start();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    await settle();
    expect(latest().review?.review.operationId).toBe("op-1");
    session.refresh("lithe-official");
    expect(latest().review).toBeNull();
    expect(service.cancelCalls).toContain("op-1");
    session.dispose();
  });

  test("a late refresh after dispose publishes nothing", async () => {
    const { service, session, states } = harness();
    session.start();
    service.listCalls[0].resolve(catalog);
    await settle();
    const published = states.length;
    session.refresh("lithe-official");
    expect(states.length).toBe(published + 1);
    const settled = states.length;
    session.dispose();
    service.refreshCalls[0]!.deferred.resolve({
      plugins: [availableEntry("io.example.alpha", "9.0.0")],
      rejected: [],
    });
    await settle();
    expect(states.length).toBe(settled);
  });
});

describe("MarketplaceSession installs", () => {
  function startedSession() {
    const context = harness();
    context.session.start();
    return context;
  }

  test("without required confirmation the review auto-confirms and records the installation", async () => {
    const installedReads: Array<ReturnType<typeof deferred<MarketplaceInstalledPlugin[]>>> = [];
    const context = harness({
      installed: () => {
        const call = deferred<MarketplaceInstalledPlugin[]>();
        installedReads.push(call);
        return call.promise;
      },
    });
    const { service, session, latest } = context;
    session.start();
    service.listCalls[0].resolve(catalog);
    installedReads[0]!.resolve([]);
    await settle();

    session.install("lithe-official", "io.example.alpha");
    expect(latest().busy["io.example.alpha"]).toBe("prepare");
    service.prepareCalls[0]!.deferred.resolve(
      reviewFixture({ operationId: "op-1", requiresConfirmation: false }),
    );
    await settle();
    expect(latest().busy["io.example.alpha"]).toBe("confirm");
    // The auto-confirm chained directly onto the resolved prepare.
    expect(service.confirmCalls[0]).toMatchObject({
      operationId: "op-1",
      manifestDigest: "digest-1",
      approved: true,
    });
    service.confirmCalls[0]!.deferred.resolve({
      pluginId: "io.example.alpha",
      version: "1.0.0",
      enabled: true,
    });
    await settle();
    // The confirm triggers an installed re-read; answer it before asserting.
    installedReads[1]!.resolve([]);
    await settle();
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    expect(latest().review).toBeNull();
    // The host answer stands in until the provider catches up.
    expect(latest().installed).toEqual([
      {
        pluginId: "io.example.alpha",
        version: "1.0.0",
        channel: { kind: "marketplace", sourceId: "lithe-official", sourceName: "Lithe" },
      },
    ]);
    session.dispose();
  });

  test("a confirmation-requiring review waits for an explicit decision on the prepared object", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    const review = reviewFixture({ operationId: "op-1" });
    service.prepareCalls[0]!.deferred.resolve(review);
    await settle();
    expect(latest().review?.review.prepared).toBe(review.prepared);
    expect(latest().review?.displayName).toBe("Plugin io.example.alpha");
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    expect(service.confirmCalls).toHaveLength(0);

    session.confirmReview();
    expect(latest().review?.confirming).toBe(true);
    expect(service.confirmCalls[0]).toMatchObject({
      operationId: "op-1",
      manifestDigest: "digest-1",
      approved: true,
    });
    service.confirmCalls[0]!.deferred.resolve({
      pluginId: "io.example.alpha",
      version: "1.0.0",
      enabled: true,
    });
    await settle();
    expect(latest().review).toBeNull();
    expect(latest().installed[0]!.channel).toEqual({
      kind: "marketplace",
      sourceId: "lithe-official",
      sourceName: "Lithe",
    });
    session.dispose();
  });

  test("rejecting the review discards the prepared snapshot", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    await settle();
    session.cancelReview();
    expect(latest().review).toBeNull();
    expect(service.cancelCalls).toContain("op-1");
    expect(service.confirmCalls).toHaveLength(0);
    session.dispose();
  });

  test("cancelling a download releases the operation and a late result only cleans up", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    expect(latest().busy["io.example.alpha"]).toBe("prepare");
    session.cancelInstall("io.example.alpha");
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    expect(service.cancelCalls).toEqual(["op-1"]);
    // The host finished the download despite the cancellation: the late
    // result must release the snapshot again and never open a review.
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    await settle();
    expect(latest().review).toBeNull();
    expect(service.cancelCalls).toEqual(["op-1", "op-1"]);
    session.dispose();
  });

  test("a cancelled download that rejects surfaces no error", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    session.cancelInstall("io.example.alpha");
    service.prepareCalls[0]!.deferred.reject(new Error("marketplace operation cancelled"));
    await settle();
    expect(latest().errors["io.example.alpha"]).toBeUndefined();
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    session.dispose();
  });

  test("switching scope cancels owned downloads, the review, and late results", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    session.scopeChanged();
    expect(service.cancelCalls).toEqual(["op-1"]);
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    await settle();
    expect(latest().review).toBeNull();
    expect(service.cancelCalls).toEqual(["op-1", "op-1"]);

    // An open review is released by a scope switch as well.
    session.install("lithe-official", "io.example.alpha");
    service.prepareCalls[1]!.deferred.resolve(reviewFixture({ operationId: "op-2" }));
    await settle();
    expect(latest().review?.review.operationId).toBe("op-2");
    session.scopeChanged();
    expect(latest().review).toBeNull();
    expect(service.cancelCalls).toContain("op-2");
    session.dispose();
  });

  test("a failed prepare records a retryable error and clears busy", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    service.prepareCalls[0]!.deferred.reject(new Error("download failed"));
    await settle();
    expect(latest().errors["io.example.alpha"]).toBe("download failed");
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    // Retrying starts a fresh operation.
    session.install("lithe-official", "io.example.alpha");
    expect(service.prepareCalls).toHaveLength(2);
    session.dispose();
  });

  test("a failed confirm closes the card, releases the review, and records the error", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    await settle();
    session.confirmReview();
    service.confirmCalls[0]!.deferred.reject(new Error("the review digest does not match"));
    await settle();
    expect(latest().review).toBeNull();
    expect(latest().errors["io.example.alpha"]).toBe("the review digest does not match");
    expect(service.cancelCalls).toContain("op-1");
    expect(latest().busy["io.example.alpha"]).toBeUndefined();
    session.dispose();
  });

  for (const outcome of ["success", "failure"] as const) {
    test(`switching source clears an in-flight confirmation and isolates its late ${outcome}`, async () => {
      const { service, session, latest } = startedSession();
      try {
        service.listCalls[0].resolve(catalog);
        await settle();
        session.install("lithe-official", "io.example.alpha");
        service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
        await settle();
        session.confirmReview();
        expect(latest().review?.confirming).toBe(true);

        session.scopeChanged();
        expect(latest().review).toBeNull();
        expect(latest().busy["io.example.alpha"]).toBeUndefined();
        expect(service.cancelCalls).toContain("op-1");

        session.install("lithe-official", "io.example.alpha");
        service.prepareCalls[1]!.deferred.resolve(reviewFixture({ operationId: "op-2" }));
        await settle();
        if (outcome === "success") {
          service.confirmCalls[0]!.deferred.resolve({
            pluginId: "io.example.alpha",
            version: "1.0.0",
            enabled: true,
          });
        } else {
          service.confirmCalls[0]!.deferred.reject(new Error("late confirmation rejection"));
        }
        await settle();
        expect(latest().review?.review.operationId).toBe("op-2");
        expect(latest().review?.confirming).toBe(false);
        expect(latest().installed).toEqual([]);
        expect(latest().errors["io.example.alpha"]).toBeUndefined();
      } finally {
        session.dispose();
        for (const call of service.prepareCalls) {
          call.deferred.resolve(reviewFixture({ operationId: call.operationId }));
        }
        for (const call of service.confirmCalls) {
          call.deferred.resolve({ pluginId: "io.example.alpha", version: "1.0.0", enabled: true });
        }
        await settle();
      }
    });
  }

  for (const requiresConfirmation of [true, false]) {
    test(`a late prepare requiring confirmation=${requiresConfirmation} cannot replace an active confirmation`, async () => {
      const { service, session, latest } = startedSession();
      const secondReview = reviewFixture({ operationId: "op-2" });
      secondReview.prepared.review.pluginId = "io.example.shared";
      try {
        service.listCalls[0].resolve(catalog);
        await settle();
        session.install("lithe-official", "io.example.alpha");
        session.install("lithe-official", "io.example.shared");
        service.prepareCalls[1]!.deferred.resolve(secondReview);
        await settle();
        session.confirmReview();

        service.prepareCalls[0]!.deferred.resolve(
          reviewFixture({ operationId: "op-1", requiresConfirmation }),
        );
        await settle();
        expect(latest().review?.review.operationId).toBe("op-2");
        expect(latest().review?.confirming).toBe(true);
        expect(latest().busy["io.example.alpha"]).toBeUndefined();
        expect(latest().busy["io.example.shared"]).toBe("confirm");
        expect(service.cancelCalls).toContain("op-1");
        expect(service.cancelCalls).not.toContain("op-2");
        expect(service.confirmCalls).toHaveLength(1);

        service.confirmCalls[0]!.deferred.resolve({
          pluginId: "io.example.shared",
          version: "1.0.0",
          enabled: true,
        });
        await settle();
        expect(latest().review).toBeNull();
        expect(latest().installed[0]?.pluginId).toBe("io.example.shared");
      } finally {
        session.dispose();
        for (const call of service.prepareCalls) {
          call.deferred.resolve(reviewFixture({ operationId: call.operationId }));
        }
        for (const call of service.confirmCalls) {
          call.deferred.resolve({ pluginId: "io.example.shared", version: "1.0.0", enabled: true });
        }
        await settle();
      }
    });
  }

  test("unavailable entries are refused without a host call", async () => {
    const { service, session, latest } = startedSession();
    service.listCalls[0].resolve([
      sourceIndex("lithe-official", "Lithe", [
        availableEntry("io.example.darwin-only", "1.0.0", {
          status: "unsupported",
          code: "plugin.index.platformUnsupported",
          platform: "darwin-arm64",
          message: "This plugin is not available for windows-x64.",
        }),
      ]),
    ]);
    await settle();
    session.install("lithe-official", "io.example.darwin-only");
    expect(service.prepareCalls).toHaveLength(0);
    expect(latest().errors["io.example.darwin-only"]).toBe(
      "This plugin is not available for windows-x64.",
    );
    session.dispose();
  });

  test("a second install for one plugin while busy is ignored", async () => {
    const { service, session } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    session.install("lithe-official", "io.example.alpha");
    expect(service.prepareCalls).toHaveLength(1);
    session.dispose();
  });

  test("dispose cancels every owned operation and stops publishing", async () => {
    const { service, session, states } = startedSession();
    service.listCalls[0].resolve(catalog);
    await settle();
    session.install("lithe-official", "io.example.alpha");
    session.refresh("lithe-official");
    const published = states.length;
    session.dispose();
    expect(service.cancelCalls).toContain("op-1");
    expect(service.cancelCalls).toContain("op-2");
    service.prepareCalls[0]!.deferred.resolve(reviewFixture({ operationId: "op-1" }));
    service.refreshCalls[0]!.deferred.resolve({ plugins: [], rejected: [] });
    await settle();
    expect(states.length).toBe(published);
  });
});

describe("mergeInstalled", () => {
  test("provider entries win and confirmed answers fill the gaps", () => {
    const providerList: MarketplaceInstalledPlugin[] = [
      { pluginId: "a", version: "1.0.0", channel: { kind: "disk" } },
    ];
    const confirmed = new Map<string, MarketplaceInstalledPlugin>([
      ["a", { pluginId: "a", version: "2.0.0", channel: { kind: "bundled" } }],
      ["b", { pluginId: "b", version: "3.0.0", channel: { kind: "bundled" } }],
    ]);
    expect(mergeInstalled(providerList, confirmed)).toEqual([
      { pluginId: "a", version: "1.0.0", channel: { kind: "disk" } },
      { pluginId: "b", version: "3.0.0", channel: { kind: "bundled" } },
    ]);
  });
});
