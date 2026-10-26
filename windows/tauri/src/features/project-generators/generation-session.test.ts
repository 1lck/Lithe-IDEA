import { expect, test } from "bun:test";
import {
  GenerationSession,
  type GenerationPort,
  type GenerationRequest,
  type GenerationReview,
} from "./generation-session";

const request: GenerationRequest = {
  pluginId: "fixture",
  generatorId: "template",
  parent: "fixture",
  createGit: false,
  form: { projectName: "Example", values: {}, edited: [], runtimes: {} },
};
const review = (id: string): GenerationReview => ({
  id,
  destination: "fixture/Example",
  plan: { steps: [], usesNetwork: false },
  programs: [],
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test("closing while preparation is pending cancels its late native ticket", async () => {
  const ready = deferred<GenerationReview>();
  const cancelled: string[] = [];
  const session = new GenerationSession({
    prepare: () => ready.promise,
    generate: async () => {
      throw new Error("unreachable");
    },
    cancel: async (id) => {
      cancelled.push(id);
    },
  });
  const pending = session.prepare(request);
  await session.close();
  ready.resolve(review("late"));
  expect(await pending).toBeUndefined();
  expect(cancelled).toEqual(["late"]);
}, 1000);

test("replaced forms cannot publish a stale preparation", async () => {
  const first = deferred<GenerationReview>();
  const second = deferred<GenerationReview>();
  const cancelled: string[] = [];
  let calls = 0;
  const session = new GenerationSession({
    prepare: () => (++calls === 1 ? first.promise : second.promise),
    generate: async () => {
      throw new Error("unreachable");
    },
    cancel: async (id) => {
      cancelled.push(id);
    },
  });
  try {
    const old = session.prepare(request);
    const current = session.prepare(request);
    second.resolve(review("current"));
    expect((await current)?.id).toBe("current");
    first.resolve(review("stale"));
    expect(await old).toBeUndefined();
    expect(cancelled).toEqual(["stale"]);
  } finally {
    await session.close();
  }
}, 1000);

test("confirmation consumes a ticket exactly once", async () => {
  const result = deferred<{ root: string; openFiles: string[] }>();
  let executions = 0;
  const session = new GenerationSession({
    prepare: async () => review("approved"),
    generate: () => {
      ++executions;
      return result.promise;
    },
    cancel: async () => {},
  });
  try {
    await session.prepare(request);
    const running = session.generate();
    await expect(session.generate()).rejects.toThrow("generator.stale");
    result.resolve({ root: "created", openFiles: [] });
    expect((await running).root).toBe("created");
    await expect(session.generate()).rejects.toThrow("generator.stale");
    expect(executions).toBe(1);
  } finally {
    await session.close();
  }
}, 1000);

test("cancellation reaches the same native operation while generation is pending", async () => {
  const result = deferred<{ root: string; openFiles: string[] }>();
  const stopped = deferred<void>();
  const cancelled: string[] = [];
  const port: GenerationPort = {
    prepare: async () => review("running"),
    generate: () => result.promise,
    cancel: async (id) => {
      cancelled.push(id);
      stopped.resolve();
    },
  };
  const session = new GenerationSession(port);
  try {
    await session.prepare(request);
    const pending = session.generate();
    await session.cancel();
    await stopped.promise;
    expect(cancelled).toEqual(["running"]);
    result.resolve({ root: "completed-before-cancel", openFiles: [] });
    expect((await pending).root).toBe("completed-before-cancel");
  } finally {
    await session.close();
  }
}, 1000);

test("cleanup failure remains retryable through close", async () => {
  let attempts = 0;
  const session = new GenerationSession({
    prepare: async () => review("retained"),
    generate: async () => {
      throw new Error("unreachable");
    },
    cancel: async () => {
      if (++attempts === 1) throw new Error("generator.cleanupFailed");
    },
  });
  await session.prepare(request);
  await expect(session.cancel()).rejects.toThrow("generator.cleanupFailed");
  await session.close();
  expect(attempts).toBe(2);
}, 1000);

test("failed native cleanup retains its operation ticket for teardown", async () => {
  const cancelled: string[] = [];
  const session = new GenerationSession({
    prepare: async () => review("retained-run"),
    generate: async () => {
      throw Object.assign(new Error("cleanup"), { code: "generator.cleanupFailed" });
    },
    cancel: async (id) => {
      cancelled.push(id);
    },
  });
  await session.prepare(request);
  await expect(session.generate()).rejects.toThrow("cleanup");
  await expect(session.prepare(request)).rejects.toThrow("generator.busy");
  await session.close();
  expect(cancelled).toEqual(["retained-run"]);
}, 1000);

test("closing during old review cleanup prevents a replacement preparation", async () => {
  const cleaned = deferred<void>();
  let preparations = 0;
  const session = new GenerationSession({
    prepare: async () => {
      ++preparations;
      return review("old");
    },
    generate: async () => {
      throw new Error("unreachable");
    },
    cancel: () => cleaned.promise,
  });
  await session.prepare(request);
  const replacement = session.prepare(request);
  const closing = session.close();
  cleaned.resolve();
  expect(await replacement).toBeUndefined();
  await closing;
  expect(preparations).toBe(1);
}, 1000);
