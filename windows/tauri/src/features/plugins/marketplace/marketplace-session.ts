import {
  type DeclarativeMarketplaceService,
  type MarketplaceIndex,
  type MarketplaceInstalledPlugin,
  type MarketplaceInstalledProvider,
  type MarketplaceReview,
  type MarketplaceSourceIndex,
} from "./marketplace-types";
import { createMarketplaceOperationIds, type MarketplaceOperationIds } from "./marketplace-service";

/**
 * State machine for one mounted marketplace browse page. It mirrors the
 * macOS `PluginMarketplaceFeatureModel` discipline adapted to the host's
 * operation registry:
 *
 * - Every read owns a generation; a superseded or disposed session drops late
 *   results instead of letting them overwrite newer state.
 * - The page owns every operation ID it creates. User cancellation, source
 *   switching, page close, and unmount release them through `cancel`, and a
 *   prepare that resolves after its attempt died is explicitly released so the
 *   host discards the prepared snapshot instead of leaking it.
 * - A refresh invalidates the host's index epoch for its source, so reviews
 *   and downloads of that source are released when it starts, not when their
 *   confirm later fails.
 * - Raw rejection strings are published; the view maps them to localized
 *   text, keeping this class free of translations.
 */

export interface MarketplaceSourceStatus {
  sourceId: string;
  sourceName: string;
  refreshing: boolean;
  /** Raw cache-read problem reported by `list`; the view describes it. */
  problem: string | null;
  /** Raw rejection from the source's latest refresh. */
  refreshError: string | null;
  rejectedCount: number;
}

export interface MarketplaceReviewCardState {
  review: MarketplaceReview;
  displayName: string;
  availableVersion: string;
  confirming: boolean;
}

export interface MarketplaceSessionState {
  load: { phase: "loading" } | { phase: "ready" } | { phase: "failed"; reason: string };
  sources: MarketplaceSourceStatus[];
  indexes: Record<string, MarketplaceIndex>;
  installed: MarketplaceInstalledPlugin[];
  /** The installed provider resolved at least once. */
  installedReady: boolean;
  /** The last installed read failed; states may be incomplete, so the page says so. */
  installedFailed: boolean;
  busy: Record<string, "prepare" | "confirm">;
  /** Raw rejection reasons by plugin ID. */
  errors: Record<string, string>;
  review: MarketplaceReviewCardState | null;
}

interface InstallAttempt {
  operationId: string;
  pluginId: string;
  sourceId: string;
  /** Install-pipeline epoch when the attempt started. */
  epoch: number;
  /** Set when the user or a scope change already released this attempt. */
  canceled: boolean;
  phase: "prepare" | "confirm";
}

/**
 * Confirmed installations are the host's authoritative answers, so they fill
 * any gap the provider has not caught up with yet; a provider entry for the
 * same plugin always wins because it is the fuller truth.
 */
export function mergeInstalled(
  providerList: MarketplaceInstalledPlugin[],
  confirmed: Iterable<[string, MarketplaceInstalledPlugin]>,
): MarketplaceInstalledPlugin[] {
  const byId = new Map(providerList.map((plugin) => [plugin.pluginId, plugin]));
  for (const [pluginId, plugin] of confirmed) {
    if (!byId.has(pluginId)) byId.set(pluginId, plugin);
  }
  return [...byId.values()];
}

export interface MarketplaceSessionOptions {
  service: DeclarativeMarketplaceService;
  installed?: MarketplaceInstalledProvider;
  publish: (state: MarketplaceSessionState) => void;
  ids?: MarketplaceOperationIds;
  log?: (message: string, reason?: unknown) => void;
}

const initialLoad: MarketplaceSessionState["load"] = { phase: "loading" };

export class MarketplaceSession {
  #service: DeclarativeMarketplaceService;
  #installed?: MarketplaceInstalledProvider;
  #publishCallback: (state: MarketplaceSessionState) => void;
  #ids: MarketplaceOperationIds;
  #log: (message: string, reason?: unknown) => void;

  #disposed = false;
  #load: MarketplaceSessionState["load"] = initialLoad;
  #loadGeneration = 0;
  #installedGeneration = 0;
  #refreshGenerations = new Map<string, number>();
  #pipelineEpoch = 0;
  #statuses: MarketplaceSourceStatus[] = [];
  #indexes = new Map<string, MarketplaceIndex>();
  #installedList: MarketplaceInstalledPlugin[] = [];
  #installedReady = false;
  #installedFailed = false;
  #confirmed = new Map<string, MarketplaceInstalledPlugin>();
  #attempts = new Map<string, InstallAttempt>();
  /** Operation IDs this page must release through `cancel`. */
  #ownedInstalls = new Map<string, string>();
  #ownedRefreshes = new Set<string>();
  #errors = new Map<string, string>();
  #review: MarketplaceReviewCardState | null = null;

  constructor(options: MarketplaceSessionOptions) {
    this.#service = options.service;
    this.#installed = options.installed;
    this.#publishCallback = options.publish;
    this.#ids = options.ids ?? createMarketplaceOperationIds();
    this.#log = options.log ?? ((message, reason) => console.warn(message, reason));
  }

  /** Loads the cached catalog. A second call supersedes a still-pending one,
   * which is what a StrictMode double mount produces. */
  start(): void {
    if (this.#disposed) return;
    const generation = ++this.#loadGeneration;
    this.#load = { phase: "loading" };
    this.#readInstalled();
    this.#publish();
    void this.#service.list().then(
      (entries) => {
        if (this.#disposed || generation !== this.#loadGeneration) return;
        this.#statuses = entries.map((entry) => this.#statusOf(entry));
        this.#indexes = new Map(
          entries
            .filter((entry) => entry.index !== null)
            .map((entry) => [entry.sourceId, entry.index as MarketplaceIndex]),
        );
        this.#load = { phase: "ready" };
        this.#publish();
      },
      (reason: unknown) => {
        if (this.#disposed || generation !== this.#loadGeneration) return;
        this.#log("marketplace list failed:", reason);
        this.#load = { phase: "failed", reason: rawMessage(reason) };
        this.#publish();
      },
    );
  }

  /** Retries a failed initial load; identical to starting again. */
  retryLoad(): void {
    this.start();
  }

  /** Refreshes one source, or every known source when `scope` is `"all"`. */
  refresh(scope: "all" | string): void {
    if (this.#disposed) return;
    const targets = scope === "all" ? this.#statuses.map((status) => status.sourceId) : [scope];
    for (const sourceId of targets) {
      if (this.#statuses.some((status) => status.sourceId === sourceId)) {
        this.#refreshSource(sourceId);
      }
    }
  }

  /** The source filter changed: the page releases its download and review
   * operations, because they belong to the source context the user left. */
  scopeChanged(): void {
    if (this.#disposed) return;
    this.#pipelineEpoch += 1;
    this.#releasePipeline();
  }

  /** Starts an install or update from one source's listing of one plugin. */
  install(sourceId: string, pluginId: string): void {
    if (this.#disposed || this.#attempts.has(pluginId)) return;
    // A confirm in flight owns the pipeline's single review slot; a download
    // started now could replace the card being committed.
    if (this.#review?.confirming) return;
    if (this.#review && this.#review.review.prepared.review.pluginId === pluginId) return;
    const entry = this.#indexes.get(sourceId)?.plugins.find((plugin) => plugin.id === pluginId);
    if (!entry) return;
    if (entry.availability.status !== "available") {
      // No host call for an entry this host cannot install; the row shows why.
      this.#errors.set(pluginId, entry.availability.message ?? entry.availability.code);
      this.#publish();
      return;
    }
    this.#errors.delete(pluginId);
    const attempt: InstallAttempt = {
      operationId: this.#ids.next(),
      pluginId,
      sourceId,
      epoch: this.#pipelineEpoch,
      canceled: false,
      phase: "prepare",
    };
    this.#attempts.set(pluginId, attempt);
    this.#ownedInstalls.set(attempt.operationId, pluginId);
    this.#publish();
    void this.#service.prepare(attempt.operationId, sourceId, pluginId).then(
      (review) => this.#prepareResolved(attempt, review),
      (reason: unknown) => this.#prepareRejected(attempt, reason),
    );
  }

  /** Cancels an in-flight download of one plugin. */
  cancelInstall(pluginId: string): void {
    const attempt = this.#attempts.get(pluginId);
    if (!attempt || attempt.phase !== "prepare") return;
    this.#dropAttempt(attempt);
    this.#publish();
  }

  /** Commits the pending review with the exact digest the host prepared. */
  confirmReview(): void {
    const pending = this.#review;
    if (!pending || pending.confirming || this.#disposed) return;
    const review = pending.review;
    const pluginId = review.prepared.review.pluginId;
    if (this.#attempts.has(pluginId)) return;
    pending.confirming = true;
    const attempt: InstallAttempt = {
      operationId: review.operationId,
      pluginId,
      sourceId: review.sourceId,
      epoch: this.#pipelineEpoch,
      canceled: false,
      phase: "confirm",
    };
    this.#attempts.set(pluginId, attempt);
    this.#publish();
    void this.#service.confirm(review.operationId, review.prepared.manifestDigest, true).then(
      (installation) => this.#confirmResolved(attempt, review, installation),
      (reason: unknown) => this.#confirmRejected(attempt, review, reason),
    );
  }

  /** Rejects the pending review; the prepared snapshot is discarded. */
  cancelReview(): void {
    const pending = this.#review;
    if (!pending || pending.confirming) return;
    this.#review = null;
    this.#releaseOperation(pending.review.operationId);
    this.#publish();
  }

  /** Ends the page: releases every owned operation and stops publishing. */
  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#pipelineEpoch += 1;
    this.#loadGeneration += 1;
    this.#installedGeneration += 1;
    for (const operationId of this.#ownedInstalls.keys()) {
      void this.#service
        .cancel(operationId)
        .catch((reason: unknown) => this.#log("marketplace cancel failed:", reason));
    }
    for (const operationId of this.#ownedRefreshes) {
      void this.#service
        .cancel(operationId)
        .catch((reason: unknown) => this.#log("marketplace cancel failed:", reason));
    }
    this.#ownedInstalls.clear();
    this.#ownedRefreshes.clear();
    this.#attempts.clear();
    this.#review = null;
  }

  // MARK: prepare / confirm

  #prepareResolved(attempt: InstallAttempt, review: MarketplaceReview): void {
    if (!this.#attemptCurrent(attempt)) {
      // The attempt was canceled, superseded, or the page closed, but the
      // host completed it: discard the prepared snapshot explicitly. The
      // earlier cancel may already have released it; canceling a finished
      // operation again is an idempotent no-op on the host.
      this.#discardResolvedPrepare(attempt.operationId);
      this.#settleAttempt(attempt);
      return;
    }
    if (this.#review?.confirming) {
      // Another download may have started before the user confirmed the current
      // card. Its late review must not replace or cancel that committed choice.
      // Release this snapshot; the row can be retried after confirmation ends.
      this.#dropAttempt(attempt);
      this.#publish();
      return;
    }
    if (!review.requiresConfirmation) {
      attempt.phase = "confirm";
      this.#publish();
      void this.#service.confirm(review.operationId, review.prepared.manifestDigest, true).then(
        (installation) => this.#confirmResolved(attempt, review, installation),
        (reason: unknown) => this.#confirmRejected(attempt, review, reason),
      );
      return;
    }
    this.#attempts.delete(attempt.pluginId);
    if (this.#review && this.#review.review.operationId !== review.operationId) {
      // One review slot: releasing the older card discards its snapshot.
      this.#releaseOperation(this.#review.review.operationId);
    }
    this.#review = {
      review,
      displayName: review.prepared.displayName,
      availableVersion: review.prepared.review.version,
      confirming: false,
    };
    this.#publish();
  }

  #prepareRejected(attempt: InstallAttempt, reason: unknown): void {
    this.#ownedInstalls.delete(attempt.operationId);
    if (!this.#attemptCurrent(attempt)) {
      this.#settleAttempt(attempt);
      return;
    }
    this.#attempts.delete(attempt.pluginId);
    this.#log("marketplace prepare failed:", reason);
    if (!isCancellation(reason)) this.#errors.set(attempt.pluginId, rawMessage(reason));
    this.#publish();
  }

  #confirmResolved(
    attempt: InstallAttempt,
    review: MarketplaceReview,
    installation: { pluginId: string; version: string; enabled: boolean },
  ): void {
    this.#ownedInstalls.delete(attempt.operationId);
    if (this.#review?.review.operationId === review.operationId) {
      this.#review = null;
    }
    if (!this.#attemptCurrent(attempt)) {
      this.#settleAttempt(attempt);
      return;
    }
    this.#attempts.delete(attempt.pluginId);
    this.#errors.delete(attempt.pluginId);
    // The host's answer is authoritative; it stands in until the installed
    // provider catches up, and never overrides a provider entry.
    this.#confirmed.set(installation.pluginId, {
      pluginId: installation.pluginId,
      version: installation.version,
      channel: {
        kind: "marketplace",
        sourceId: review.sourceId,
        sourceName: review.sourceName,
      },
    });
    this.#publish();
    this.#readInstalled();
  }

  #confirmRejected(attempt: InstallAttempt, review: MarketplaceReview, reason: unknown): void {
    // A rejected check leaves the prepared review registered on the host.
    this.#releaseOperation(review.operationId);
    if (this.#review?.review.operationId === review.operationId) {
      this.#review = null;
    }
    if (!this.#attemptCurrent(attempt)) {
      this.#settleAttempt(attempt);
      return;
    }
    this.#attempts.delete(attempt.pluginId);
    this.#log("marketplace confirm failed:", reason);
    if (!isCancellation(reason)) this.#errors.set(attempt.pluginId, rawMessage(reason));
    this.#publish();
  }

  // MARK: refresh

  #refreshSource(sourceId: string): void {
    const status = this.#statuses.find((entry) => entry.sourceId === sourceId);
    if (!status || status.refreshing) return;
    // The host bumps its index epoch for this source, which invalidates every
    // review and download from it; release them now instead of failing later.
    this.#cancelInstallsForSource(sourceId);
    const operationId = this.#ids.next();
    const generation = (this.#refreshGenerations.get(sourceId) ?? 0) + 1;
    this.#refreshGenerations.set(sourceId, generation);
    this.#ownedRefreshes.add(operationId);
    status.refreshing = true;
    this.#publish();
    void this.#service.refresh(operationId, sourceId).then(
      (index) => {
        this.#ownedRefreshes.delete(operationId);
        if (this.#disposed || generation !== this.#refreshGenerations.get(sourceId)) return;
        status.refreshing = false;
        status.refreshError = null;
        status.problem = null;
        status.rejectedCount = index.rejected.length;
        this.#indexes.set(sourceId, index);
        this.#publish();
        // Native provenance is reported for IDs in the cached index. Recovering
        // a missing/older index may make an installed package's source known,
        // so update eligibility must be re-read together with the new catalog.
        this.#readInstalled();
      },
      (reason: unknown) => {
        this.#ownedRefreshes.delete(operationId);
        if (this.#disposed || generation !== this.#refreshGenerations.get(sourceId)) return;
        status.refreshing = false;
        this.#log("marketplace refresh failed:", reason);
        status.refreshError = rawMessage(reason);
        this.#publish();
      },
    );
  }

  // MARK: ownership helpers

  /** Releases the pipeline: downloads stop, the review card closes, and every
   * owned install operation — a confirm included — is canceled on the host. A
   * confirm already committed server-side is unaffected by the extra cancel,
   * and its settle path then only cleans up. */
  #releasePipeline(): void {
    for (const attempt of this.#attempts.values()) {
      this.#dropAttempt(attempt);
    }
    if (this.#review) {
      const operationId = this.#review.review.operationId;
      this.#review = null;
      this.#releaseOperation(operationId);
    }
    this.#publish();
  }

  #cancelInstallsForSource(sourceId: string): void {
    for (const attempt of this.#attempts.values()) {
      if (attempt.sourceId === sourceId) this.#dropAttempt(attempt);
    }
    if (this.#review && this.#review.review.sourceId === sourceId) {
      const operationId = this.#review.review.operationId;
      this.#review = null;
      this.#releaseOperation(operationId);
    }
  }

  /** Marks an attempt dead, forgets its busy state, and releases its host
   * operation. The pending promise still settles into a cleanup-only path. */
  #dropAttempt(attempt: InstallAttempt): void {
    attempt.canceled = true;
    if (this.#attempts.get(attempt.pluginId) === attempt) {
      this.#attempts.delete(attempt.pluginId);
    }
    this.#releaseOperation(attempt.operationId);
  }

  /** Cancels one operation this page owns and forgets the ownership. */
  #releaseOperation(operationId: string): void {
    if (!this.#ownedInstalls.delete(operationId)) return;
    void this.#service
      .cancel(operationId)
      .catch((reason: unknown) => this.#log("marketplace cancel failed:", reason));
  }

  /** A prepare that resolved for a dead attempt still holds a host snapshot;
   * discarding it is unconditional because the earlier release may have raced
   * with the download's completion. */
  #discardResolvedPrepare(operationId: string): void {
    this.#ownedInstalls.delete(operationId);
    void this.#service
      .cancel(operationId)
      .catch((reason: unknown) => this.#log("marketplace cancel failed:", reason));
  }

  #attemptCurrent(attempt: InstallAttempt): boolean {
    return !this.#disposed && !attempt.canceled && attempt.epoch === this.#pipelineEpoch;
  }

  #settleAttempt(attempt: InstallAttempt): void {
    if (this.#attempts.get(attempt.pluginId) === attempt) {
      this.#attempts.delete(attempt.pluginId);
    }
    this.#publish();
  }

  // MARK: installed + state

  #readInstalled(): void {
    if (!this.#installed) return;
    const generation = ++this.#installedGeneration;
    void this.#installed().then(
      (plugins) => {
        if (this.#disposed || generation !== this.#installedGeneration) return;
        const byId = new Map<string, MarketplaceInstalledPlugin>();
        for (const plugin of plugins) {
          if (!byId.has(plugin.pluginId)) byId.set(plugin.pluginId, plugin);
        }
        this.#installedList = [...byId.values()];
        this.#installedReady = true;
        this.#installedFailed = false;
        this.#publish();
      },
      (reason: unknown) => {
        if (this.#disposed || generation !== this.#installedGeneration) return;
        this.#log("marketplace installed read failed:", reason);
        this.#installedFailed = true;
        this.#publish();
      },
    );
  }

  #statusOf(entry: MarketplaceSourceIndex): MarketplaceSourceStatus {
    const existing = this.#statuses.find((status) => status.sourceId === entry.sourceId);
    return {
      sourceId: entry.sourceId,
      sourceName: entry.sourceName,
      // A refresh the page already started keeps running across the reload.
      refreshing: existing?.refreshing ?? false,
      problem: entry.problem,
      refreshError: existing?.refreshError ?? null,
      rejectedCount: entry.index?.rejected.length ?? existing?.rejectedCount ?? 0,
    };
  }

  #publish(): void {
    if (this.#disposed) return;
    this.#publishCallback({
      load: this.#load,
      sources: this.#statuses.map((status) => ({ ...status })),
      indexes: Object.fromEntries(this.#indexes),
      installed: mergeInstalled(this.#installedList, this.#confirmed),
      installedReady: this.#installedReady,
      installedFailed: this.#installedFailed,
      busy: Object.fromEntries(
        [...this.#attempts].map(([pluginId, attempt]) => [pluginId, attempt.phase]),
      ),
      errors: Object.fromEntries(this.#errors),
      review: this.#review ? { ...this.#review } : null,
    });
  }
}

function rawMessage(reason: unknown): string {
  if (typeof reason === "object" && reason !== null && "message" in reason) {
    return String((reason as { message: unknown }).message);
  }
  return String(reason);
}

/** Matches the host's stable cancellation wording; see describeMarketplaceError. */
function isCancellation(reason: unknown): boolean {
  return rawMessage(reason).includes("marketplace operation cancelled");
}
