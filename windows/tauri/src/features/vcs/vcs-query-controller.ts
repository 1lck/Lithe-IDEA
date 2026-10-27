import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot } from "./vcs-root-types";
import type {
  VcsBaseContent,
  VcsHistoryEntry,
  VcsHistoryPage,
  VcsQuerySnapshot,
  VcsReadQuery,
} from "./vcs-query-types";

export const HISTORY_PAGE_SIZE = 50;
export const MAX_HISTORY_ENTRIES = 500;
const MAX_HISTORY_PAGES = 20;
type Phase = "idle" | "loading" | "ready" | "failed" | "stopping" | "cancelFailed";
export interface VcsQueryState {
  phase: Phase;
  rootId: string | null;
  path: string | null;
  entries: VcsHistoryEntry[];
  nextCursor: string | null;
  limited: boolean;
  error: unknown;
}
interface Attempt {
  id: string;
  source: VcsSnapshot;
  rootId: string;
  controller: AbortController;
  cancellation: Promise<void> | null;
}
/** User initiated reads share the native status owner, cancellation endpoint
 * and disposal proof. A cursor is opaque and only belongs to this source. */
export class VcsQueryController {
  #state: VcsQueryState = {
    phase: "idle",
    rootId: null,
    path: null,
    entries: [],
    nextCursor: null,
    limited: false,
    error: null,
  };
  #attempt: Attempt | null = null;
  #source: VcsSnapshot | null = null;
  #cursors = new Set<string>();
  #pages = 0;
  #closed = false;
  #listeners = new Set<() => void>();
  constructor(
    private roots: VcsRootController,
    private port: VcsRootPort,
  ) {}
  getSnapshot = () => this.#state;
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  get busy() {
    return this.#attempt !== null;
  }
  #publish(patch: Partial<VcsQueryState>) {
    this.#state = { ...this.#state, ...patch };
    for (const listener of this.#listeners) listener();
  }
  #bounded<T>(start: () => Promise<T>, signal?: AbortSignal, long = false): Promise<T> {
    return new Promise((resolve, reject) => {
      let ended = false;
      let stopDeadline = () => {};
      const finish = (value: T | null, error?: unknown) => {
        if (ended) return;
        ended = true;
        stopDeadline();
        signal?.removeEventListener("abort", abort);
        if (error) reject(error);
        else resolve(value!);
      };
      const abort = () => finish(null, new Error("requestCancelled"));
      signal?.addEventListener("abort", abort, { once: true });
      stopDeadline = (long ? (this.port.statusDeadline ?? this.port.deadline) : this.port.deadline)(
        () => finish(null, new Error("requestTimeout")),
      );
      if (signal?.aborted) abort();
      if (ended) stopDeadline();
      else
        Promise.resolve()
          .then(() => {
            if (ended) throw new Error("requestCancelled");
            return start();
          })
          .then(
            (value) => finish(value),
            (error: unknown) => finish(null, error),
          );
    });
  }
  async #read(rootId: string, query: VcsReadQuery): Promise<VcsQuerySnapshot | null> {
    const source = this.roots.getSnapshot().snapshot;
    const root = source?.detection.roots.find((root) => root.id === rootId);
    const statusPhase = this.roots.status.getSnapshot().phase;
    if (
      this.#closed ||
      this.#attempt ||
      ["loading", "stopping", "cancelFailed"].includes(statusPhase) ||
      !source ||
      source.detection.truncated ||
      !root ||
      !source.detection.providers.some(
        (provider) => provider.vcs === root.vcs && provider.origin.kind === "plugin",
      )
    )
      return null;
    const attempt: Attempt = {
      id: crypto.randomUUID(),
      source,
      rootId,
      controller: new AbortController(),
      cancellation: null,
    };
    this.#attempt = attempt;
    this.#publish({ phase: "loading", error: null });
    try {
      const answer = await this.#bounded(
        () => {
          if (!this.port.query) throw new Error("vcs.provider.unavailable");
          return this.port.query(this.roots.scope, source.generation, rootId, attempt.id, query);
        },
        attempt.controller.signal,
        true,
      );
      if (
        this.#closed ||
        this.#attempt !== attempt ||
        attempt.controller.signal.aborted ||
        this.roots.getSnapshot().snapshot !== source
      )
        return null;
      if (
        !answer ||
        answer.requestId !== attempt.id ||
        answer.generation !== source.generation ||
        answer.rootId !== rootId ||
        answer.vcs !== root.vcs ||
        answer.operation !== query.operation
      )
        throw new Error("invalidResponse");
      this.#attempt = null;
      this.#publish({ phase: "ready", error: null });
      return answer;
    } catch (error) {
      if (this.#attempt !== attempt) return null;
      const cancelled = attempt.controller.signal.aborted;
      try {
        await this.#cancel(attempt);
        if (!this.#closed && !cancelled) this.#publish({ phase: "failed", error });
      } catch {
        /* Keep the exact native owner available for Retry Stop. */
      }
      return null;
    }
  }
  async history(rootId: string, path: string | null = null): Promise<void> {
    if (this.#closed || this.#attempt) return;
    this.#source = this.roots.getSnapshot().snapshot;
    this.#cursors.clear();
    this.#pages = 0;
    this.#publish({ rootId, path, entries: [], nextCursor: null, limited: false });
    await this.#page(null);
  }
  async more(): Promise<void> {
    if (this.#state.nextCursor !== null && !this.#state.limited)
      await this.#page(this.#state.nextCursor);
  }
  async #page(cursor: string | null) {
    const source = this.#source;
    const { rootId, path } = this.#state;
    if (!source || rootId === null || source !== this.roots.getSnapshot().snapshot || this.#attempt)
      return;
    const remaining = MAX_HISTORY_ENTRIES - this.#state.entries.length;
    if (remaining <= 0 || this.#pages >= MAX_HISTORY_PAGES) {
      this.#publish({ limited: true });
      return;
    }
    const query: VcsReadQuery =
      path === null
        ? { operation: "history", cursor, limit: Math.min(HISTORY_PAGE_SIZE, remaining) }
        : { operation: "fileHistory", path, cursor, limit: Math.min(HISTORY_PAGE_SIZE, remaining) };
    const answer = await this.#read(rootId, query);
    if (!answer || this.#source !== source || this.roots.getSnapshot().snapshot !== source) return;
    const page = answer.result as VcsHistoryPage;
    if (
      !Array.isArray(page.entries) ||
      page.entries.length > query.limit ||
      !(
        page.nextCursor === null ||
        (typeof page.nextCursor === "string" &&
          page.nextCursor.length > 0 &&
          page.nextCursor.length <= 256 &&
          !/[\u0000-\u001f\u007f]/u.test(page.nextCursor))
      ) ||
      page.entries.some(
        (entry) =>
          !entry?.revision ||
          typeof entry.revision.id !== "string" ||
          typeof entry.revision.display !== "string" ||
          typeof entry.message !== "string" ||
          !Array.isArray(entry.changes) ||
          typeof entry.changesTruncated !== "boolean",
      )
    ) {
      this.#publish({
        phase: "failed",
        error: new Error("plugin.vcs.invalidOutput"),
        nextCursor: null,
      });
      return;
    }
    if (cursor !== null) this.#cursors.add(cursor);
    ++this.#pages;
    const entries = [...this.#state.entries, ...page.entries];
    if (page.nextCursor !== null && this.#cursors.has(page.nextCursor)) {
      this.#publish({
        phase: "failed",
        entries,
        nextCursor: null,
        error: new Error("vcs.history.cursorRepeated"),
      });
      return;
    }
    this.#publish({
      entries,
      nextCursor: page.nextCursor,
      limited:
        page.nextCursor !== null &&
        (entries.length >= MAX_HISTORY_ENTRIES || this.#pages >= MAX_HISTORY_PAGES),
    });
  }
  async compare(
    rootId: string,
    path: string,
    currentPath: string,
    publish: (result: VcsBaseContent) => void,
  ): Promise<void> {
    const source = this.roots.getSnapshot().snapshot;
    const answer = await this.#read(rootId, { operation: "baseContent", path, currentPath });
    if (!answer || this.roots.getSnapshot().snapshot !== source || this.#closed) return;
    const result = answer.result as VcsBaseContent;
    if (
      result.path !== path ||
      result.currentPath !== currentPath ||
      typeof result.binary !== "boolean" ||
      typeof result.currentBinary !== "boolean" ||
      !(result.content === null || typeof result.content === "string") ||
      !(result.currentContent === null || typeof result.currentContent === "string")
    ) {
      this.#publish({ phase: "failed", error: new Error("plugin.vcs.invalidOutput") });
      return;
    }
    try {
      publish(result);
    } catch (error) {
      this.#publish({ phase: "failed", error });
    }
  }
  async #cancel(attempt: Attempt): Promise<void> {
    if (attempt.cancellation) return attempt.cancellation;
    attempt.controller.abort();
    this.#publish({ phase: "stopping", error: null });
    const pending = this.#bounded(async () => {
      if (!this.port.cancelStatus) throw new Error("vcs.provider.unavailable");
      await this.port.cancelStatus(this.roots.scope, attempt.id);
    });
    attempt.cancellation = pending;
    try {
      await pending;
      if (this.#attempt === attempt) {
        this.#attempt = null;
        this.#publish({ phase: "idle" });
      }
    } catch (error) {
      attempt.cancellation = null;
      if (this.#attempt === attempt) this.#publish({ phase: "cancelFailed", error });
      throw error;
    }
  }
  cancel(): Promise<void> {
    return this.#attempt ? this.#cancel(this.#attempt) : Promise.resolve();
  }
  invalidate() {
    this.#source = null;
    this.#cursors.clear();
    this.#publish({ entries: [], nextCursor: null, rootId: null, path: null, limited: false });
    if (this.#attempt) void this.cancel().catch(() => {});
    else this.#publish({ phase: "idle", error: null });
  }
  async close() {
    this.#closed = true;
    this.invalidate();
    await this.cancel();
    this.#listeners.clear();
  }
}
