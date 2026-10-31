import { describe, expect, mock, spyOn, test } from "bun:test";
import { createFileWatcherStore, type FileWatcherInvoke } from "./file-watcher.store";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

describe("file watcher lifecycle", () => {
  test("stops every explicit watch when the project root is cleared", async () => {
    const invokeCommand = mock(
      async (_command: string, _arguments: Parameters<FileWatcherInvoke>[1]): Promise<unknown> => undefined,
    );
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);
    await store.getState().actions.setProjectRoot("D:/work");
    await store.getState().actions.startWatching("D:/work/pom.xml");
    await store.getState().actions.startWatching("D:/work/module/pom.xml");
    invokeCommand.mockClear();

    await store.getState().actions.setProjectRoot("");

    expect(invokeCommand.mock.calls).toEqual([
      ["stop_watching", { path: "D:/work/pom.xml", runtimeId: expect.any(String), watchId: expect.any(String) }],
      ["stop_watching", { path: "D:/work/module/pom.xml", runtimeId: expect.any(String), watchId: expect.any(String) }],
      ["stop_watching", { path: "D:/work", runtimeId: expect.any(String), watchId: expect.any(String) }],
    ]);
    expect(store.getState().watchedPaths.size).toBe(0);
  });

  test("retains an explicit watch when native cleanup fails", async () => {
    const invokeCommand = mock(async (command: string, arguments_: Parameters<FileWatcherInvoke>[1]) => {
      if (command === "stop_watching" && arguments_.path.endsWith("module/pom.xml")) {
        throw new Error("native watcher remained active");
      }
      return undefined;
    });
    const consoleError = spyOn(console, "error").mockImplementation(() => undefined);
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);

    try {
      await store.getState().actions.setProjectRoot("D:/work");
      await store.getState().actions.startWatching("D:/work/pom.xml");
      await store.getState().actions.startWatching("D:/work/module/pom.xml");
      await store.getState().actions.setProjectRoot("");

      expect([...store.getState().watchedPaths]).toEqual(["D:/work/module/pom.xml"]);
      expect(consoleError).toHaveBeenCalledWith(
        "Failed to stop watching:",
        "D:/work/module/pom.xml",
        expect.any(Error),
      );
    } finally {
      consoleError.mockRestore();
    }
  });

  test("orders root cleanup after an in-flight explicit watch registration", async () => {
    const registrationStarted = deferred<void>();
    const releaseRegistration = deferred<void>();
    const invokeCommand = mock(async (command: string, _arguments: Parameters<FileWatcherInvoke>[1]) => {
      if (command === "start_watching") {
        registrationStarted.resolve(undefined);
        await releaseRegistration.promise;
      }
      return undefined;
    });
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);
    await store.getState().actions.setProjectRoot("D:/work");
    invokeCommand.mockClear();
    const registration = store.getState().actions.startWatching("D:/work/module/pom.xml");
    await registrationStarted.promise;
    const cleanup = store.getState().actions.setProjectRoot("");

    try {
      releaseRegistration.resolve(undefined);
      await registration;
      await cleanup;

      expect(invokeCommand.mock.calls).toEqual([
        ["start_watching", { path: "D:/work/module/pom.xml", runtimeId: expect.any(String), watchId: expect.any(String) }],
        ["stop_watching", { path: "D:/work/module/pom.xml", runtimeId: expect.any(String), watchId: expect.any(String) }],
        ["stop_watching", { path: "D:/work", runtimeId: expect.any(String), watchId: expect.any(String) }],
      ]);
      expect(store.getState().watchedPaths.size).toBe(0);
      expect(await store.getState().actions.startWatching("D:/work/pom.xml")).toBe(false);
    } finally {
      releaseRegistration.resolve(undefined);
      await registration;
      await cleanup;
    }
  });

  test("unwatches the previous project root before registering its replacement", async () => {
    const invokeCommand = mock(
      async (_command: string, _arguments: Parameters<FileWatcherInvoke>[1]): Promise<unknown> => undefined,
    );
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);
    await store.getState().actions.setProjectRoot("D:/first");
    await store.getState().actions.startWatching("D:/first/pom.xml");
    invokeCommand.mockClear();

    expect(await store.getState().actions.setProjectRoot("D:/second")).toBe(true);

    expect(invokeCommand.mock.calls).toEqual([
      ["stop_watching", { path: "D:/first/pom.xml", runtimeId: expect.any(String), watchId: expect.any(String) }],
      ["stop_watching", { path: "D:/first", runtimeId: expect.any(String), watchId: expect.any(String) }],
      ["set_project_root", { path: "D:/second", runtimeId: expect.any(String), watchId: expect.any(String) }],
    ]);
    expect(store.getState().projectRoot).toBe("D:/second");
  });

  test("retains the project root when native root cleanup fails", async () => {
    let rejectRootCleanup = true;
    const invokeCommand = mock(
      async (command: string, arguments_: Parameters<FileWatcherInvoke>[1]): Promise<unknown> => {
        if (command === "stop_watching" && arguments_.path === "D:/work" && rejectRootCleanup) {
          rejectRootCleanup = false;
          throw new Error("root cleanup failed");
        }
        return undefined;
      },
    );
    const consoleError = spyOn(console, "error").mockImplementation(() => undefined);
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);

    try {
      await store.getState().actions.setProjectRoot("D:/work");

      expect(await store.getState().actions.setProjectRoot("")).toBe(false);
      expect(store.getState().projectRoot).toBe("D:/work");

      expect(await store.getState().actions.setProjectRoot("")).toBe(true);
      expect(store.getState().projectRoot).toBe("");
    } finally {
      consoleError.mockRestore();
    }
  });
});


test("shared paths keep separate runtime registrations and release their own identifiers", async () => {
  const native = mock(async (_command: string, _args: Parameters<FileWatcherInvoke>[1]) => undefined);
  const first = createFileWatcherStore("first", native);
  const second = createFileWatcherStore("second", native);
  try {
    await first.getState().actions.setProjectRoot("C:/shared");
    await second.getState().actions.setProjectRoot("C:/shared");
    const a = native.mock.calls[0]![1];
    const b = native.mock.calls[1]![1];
    expect(a.runtimeId).not.toBe(b.runtimeId);
    expect(a.watchId).not.toBe(b.watchId);
    await first.getState().actions.setProjectRoot("");
    expect(native.mock.calls[2]).toEqual(["stop_watching", a]);
    expect(second.getState().projectRoot).toBe("C:/shared");
    await second.getState().actions.setProjectRoot("");
    expect(native.mock.calls[3]).toEqual(["stop_watching", b]);
  } finally {
    await first.getState().actions.setProjectRoot("");
    await second.getState().actions.setProjectRoot("");
  }
});
