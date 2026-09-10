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
      async (_command: string, _arguments: { path: string }): Promise<unknown> => undefined,
    );
    const store = createFileWatcherStore("workspace", invokeCommand as FileWatcherInvoke);
    await store.getState().actions.setProjectRoot("D:/work");
    await store.getState().actions.startWatching("D:/work/pom.xml");
    await store.getState().actions.startWatching("D:/work/module/pom.xml");
    invokeCommand.mockClear();

    await store.getState().actions.setProjectRoot("");

    expect(invokeCommand.mock.calls).toEqual([
      ["stop_watching", { path: "D:/work/pom.xml" }],
      ["stop_watching", { path: "D:/work/module/pom.xml" }],
      ["set_project_root", { path: "" }],
    ]);
    expect(store.getState().watchedPaths.size).toBe(0);
  });

  test("retains an explicit watch when native cleanup fails", async () => {
    const invokeCommand = mock(async (command: string, arguments_: { path: string }) => {
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
    const invokeCommand = mock(async (command: string, _arguments: { path: string }) => {
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
        ["start_watching", { path: "D:/work/module/pom.xml" }],
        ["stop_watching", { path: "D:/work/module/pom.xml" }],
        ["set_project_root", { path: "" }],
      ]);
      expect(store.getState().watchedPaths.size).toBe(0);
      expect(await store.getState().actions.startWatching("D:/work/pom.xml")).toBe(false);
    } finally {
      releaseRegistration.resolve(undefined);
      await registration;
      await cleanup;
    }
  });
});
