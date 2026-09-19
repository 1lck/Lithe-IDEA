import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type { SessionRestoreController } from "./workspace-session-restore";

// The controller reads local files through `loadFileContent`, which delegates to
// `readFileContent` for local (non-remote/non-wsl) paths. Mocking that one
// function lets us drive read timing deterministically without touching the
// filesystem.
const readFileContent = mock(async (_path: string): Promise<string> => "");

mock.module("./file-operations", () => ({ readFileContent }));

const { createSessionRestoreController, SESSION_RESTORE_CONCURRENCY } =
  await import("./workspace-session-restore");

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
}

const controllers = new Set<SessionRestoreController>();
const pendingReads = new Set<Deferred<string>>();

function deferRead(): Deferred<string> {
  let resolve!: (value: string) => void;
  const deferred: Deferred<string> = {
    promise: new Promise<string>((nextResolve) => {
      resolve = nextResolve;
    }),
    resolve(value) {
      pendingReads.delete(deferred);
      resolve(value);
    },
  };
  pendingReads.add(deferred);
  return deferred;
}

async function flushRestoreWork() {
  await Promise.resolve();
  await Promise.resolve();
}

beforeEach(() => {
  readFileContent.mockReset();
  readFileContent.mockResolvedValue("");
});

afterEach(async () => {
  for (const controller of controllers) controller.dispose();
  controllers.clear();
  for (const pending of pendingReads) pending.resolve("");
  await flushRestoreWork();
});

interface Harness {
  controller: ReturnType<typeof createSessionRestoreController>;
  markLoading: ReturnType<typeof mock>;
  applyLoaded: ReturnType<typeof mock>;
  markFailed: ReturnType<typeof mock>;
  isCurrent: ReturnType<typeof mock>;
  isBufferValid: ReturnType<typeof mock>;
  validPaths: Map<string, string>;
  setCurrent: (value: boolean) => void;
}

function makeHarness(): Harness {
  const markLoading = mock((_id: string) => {});
  const applyLoaded = mock((_id: string, _loaded: unknown, _state?: unknown) => {});
  const markFailed = mock((_id: string, _error: string) => {});
  let current = true;
  const validPaths = new Map<string, string>();
  const isCurrent = mock(() => current);
  const isBufferValid = mock((id: string, path: string) => validPaths.get(id) === path);

  const controller = createSessionRestoreController({
    markLoading,
    applyLoaded,
    markFailed,
    isCurrent,
    isBufferValid,
  });
  controllers.add(controller);

  return {
    controller,
    markLoading,
    applyLoaded,
    markFailed,
    isCurrent,
    isBufferValid,
    validPaths,
    setCurrent: (value) => {
      current = value;
    },
  };
}

describe("createSessionRestoreController", () => {
  test("loads at most SESSION_RESTORE_CONCURRENCY buffers concurrently", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const pending = new Map<string, Deferred<string>>();
    readFileContent.mockImplementation((path: string) => {
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      const deferred = deferRead();
      pending.set(path, deferred);
      return deferred.promise.finally(() => {
        inFlight -= 1;
      });
    });

    const h = makeHarness();
    const paths = ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts"];
    for (const path of paths) h.validPaths.set(`id_${path}`, path);

    h.controller.enqueue(paths.map((path) => ({ bufferId: `id_${path}`, path })));

    expect(readFileContent).toHaveBeenCalledTimes(SESSION_RESTORE_CONCURRENCY);
    expect(maxInFlight).toBe(SESSION_RESTORE_CONCURRENCY);

    // Resolving one job lets the next start without exceeding the cap.
    pending.get("a.ts")!.resolve("content");
    await flushRestoreWork();
    expect(maxInFlight).toBe(SESSION_RESTORE_CONCURRENCY);
    expect(readFileContent).toHaveBeenCalledTimes(SESSION_RESTORE_CONCURRENCY + 1);
  });

  test("dedupes jobs by path within the queue", () => {
    readFileContent.mockResolvedValue("content");
    const h = makeHarness();
    h.validPaths.set("id_1", "a.ts");
    h.validPaths.set("id_2", "a.ts");

    h.controller.enqueue([
      { bufferId: "id_1", path: "a.ts" },
      { bufferId: "id_2", path: "a.ts" },
    ]);

    expect(readFileContent).toHaveBeenCalledTimes(1);
  });

  test("promote loads a queued buffer immediately, ahead of the queue", () => {
    const readOrder: string[] = [];
    readFileContent.mockImplementation((path: string) => {
      readOrder.push(path);
      return deferRead().promise;
    });

    const h = makeHarness();
    const paths = ["a.ts", "b.ts", "c.ts", "d.ts"];
    for (const path of paths) h.validPaths.set(`id_${path}`, path);

    h.controller.enqueue(paths.map((path) => ({ bufferId: `id_${path}`, path })));
    // a.ts and b.ts fill the concurrency slots, then c.ts jumps ahead of d.ts.
    h.controller.promote("id_c.ts");

    expect(readOrder).toEqual(["a.ts", "b.ts", "c.ts"]);
    expect(h.controller.pendingCount()).toBe(1); // d.ts still queued
  });

  test("loadNow loads a single job immediately and awaits it", async () => {
    readFileContent.mockResolvedValue("hello");
    const h = makeHarness();
    h.validPaths.set("id_1", "a.ts");

    await h.controller.loadNow({ bufferId: "id_1", path: "a.ts" });

    expect(h.applyLoaded).toHaveBeenCalledWith(
      "id_1",
      expect.objectContaining({ kind: "text", content: "hello" }),
      undefined,
    );
    expect(readFileContent).toHaveBeenCalledTimes(1);
  });

  test("loadNow preserves the persisted editor state of a queued job", async () => {
    readFileContent.mockImplementation((path: string) =>
      path === "c.ts" ? Promise.resolve("content") : deferRead().promise,
    );
    const h = makeHarness();
    for (const path of ["a.ts", "b.ts", "c.ts"]) h.validPaths.set(`id_${path}`, path);
    const editorState = { cursor: { line: 4, column: 2, offset: 14 }, scrollTop: 96 };

    h.controller.enqueue([
      { bufferId: "id_a.ts", path: "a.ts" },
      { bufferId: "id_b.ts", path: "b.ts" },
      { bufferId: "id_c.ts", path: "c.ts", editorState },
    ]);
    await h.controller.loadNow({ bufferId: "id_c.ts", path: "c.ts" });

    expect(h.applyLoaded).toHaveBeenCalledWith(
      "id_c.ts",
      expect.objectContaining({ kind: "text", content: "content" }),
      editorState,
    );
  });

  test("drops a result when the workspace is no longer current", async () => {
    const pending = new Map<string, Deferred<string>>();
    readFileContent.mockImplementation(
      (path: string) => {
        const deferred = deferRead();
        pending.set(path, deferred);
        return deferred.promise;
      },
    );

    const h = makeHarness();
    h.validPaths.set("id_1", "a.ts");
    h.controller.enqueue([{ bufferId: "id_1", path: "a.ts" }]);

    h.setCurrent(false); // workspace switched away while reading
    pending.get("a.ts")!.resolve("content");
    await flushRestoreWork();

    expect(h.applyLoaded).not.toHaveBeenCalled();
    expect(h.markFailed).not.toHaveBeenCalled();
  });

  test("drops a result when the tab was closed", async () => {
    const pending = new Map<string, Deferred<string>>();
    readFileContent.mockImplementation(
      (path: string) => {
        const deferred = deferRead();
        pending.set(path, deferred);
        return deferred.promise;
      },
    );

    const h = makeHarness();
    h.validPaths.set("id_1", "a.ts");
    h.controller.enqueue([{ bufferId: "id_1", path: "a.ts" }]);

    h.validPaths.delete("id_1"); // tab closed while reading
    pending.get("a.ts")!.resolve("content");
    await flushRestoreWork();

    expect(h.applyLoaded).not.toHaveBeenCalled();
  });

  test("marks a buffer as failed when the read throws", async () => {
    readFileContent.mockRejectedValue(new Error("boom"));
    const h = makeHarness();
    h.validPaths.set("id_1", "a.ts");
    h.controller.enqueue([{ bufferId: "id_1", path: "a.ts" }]);

    await flushRestoreWork();

    expect(h.markFailed).toHaveBeenCalledWith("id_1", "boom");
    expect(h.applyLoaded).not.toHaveBeenCalled();
  });

  test("dispose stops pending work and ignores in-flight completion", async () => {
    const pending = new Map<string, Deferred<string>>();
    readFileContent.mockImplementation(
      (path: string) => {
        const deferred = deferRead();
        pending.set(path, deferred);
        return deferred.promise;
      },
    );

    const h = makeHarness();
    const paths = ["a.ts", "b.ts", "c.ts"];
    for (const path of paths) h.validPaths.set(`id_${path}`, path);

    h.controller.enqueue(paths.map((path) => ({ bufferId: `id_${path}`, path })));
    expect(h.controller.pendingCount()).toBe(paths.length - SESSION_RESTORE_CONCURRENCY);

    h.controller.dispose();
    expect(h.controller.pendingCount()).toBe(0);

    // Completing an already-in-flight read must not surface a result.
    pending.get("a.ts")!.resolve("content");
    await flushRestoreWork();
    expect(h.applyLoaded).not.toHaveBeenCalled();
  });
});
