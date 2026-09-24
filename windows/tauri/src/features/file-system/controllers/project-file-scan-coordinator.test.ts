import { expect, test } from "bun:test";
import { createProjectFileScanCoordinator } from "./project-file-scan-coordinator";

type Deferred<Value> = {
  promise: Promise<Value>;
  resolve: (value: Value) => void;
  reject: (reason: unknown) => void;
};

function deferred<Value>(): Deferred<Value> {
  let resolve!: (value: Value) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<Value>((resolver, rejecter) => {
    resolve = resolver;
    reject = rejecter;
  });
  return { promise, resolve, reject };
}

test("joins concurrent project-file scans for the same workspace generation", async () => {
  const coordinate = createProjectFileScanCoordinator<string[]>();
  const scan = deferred<string[]>();
  let starts = 0;
  const startScan = () => {
    starts += 1;
    return scan.promise;
  };

  const first = coordinate("C:/repo\0revision-1", startScan);
  const second = coordinate("C:/repo\0revision-1", startScan);
  expect(first).toBe(second);
  expect(starts).toBe(1);

  scan.resolve(["pom.xml"]);
  expect(await first).toEqual(["pom.xml"]);
  expect(await second).toEqual(["pom.xml"]);
});

test("keeps identical scans joined when another workspace scan starts between them", async () => {
  const coordinate = createProjectFileScanCoordinator<string[]>();
  const firstWorkspaceScan = deferred<string[]>();
  const secondWorkspaceScan = deferred<string[]>();
  let firstWorkspaceStarts = 0;

  const first = coordinate("C:/repo-a", () => {
    firstWorkspaceStarts += 1;
    return firstWorkspaceScan.promise;
  });
  const second = coordinate("C:/repo-b", () => secondWorkspaceScan.promise);
  const joinedFirst = coordinate("C:/repo-a", () => {
    firstWorkspaceStarts += 1;
    return Promise.resolve([]);
  });

  expect(joinedFirst).toBe(first);
  expect(firstWorkspaceStarts).toBe(1);

  firstWorkspaceScan.resolve(["pom.xml"]);
  secondWorkspaceScan.resolve(["settings.gradle"]);
  expect(await joinedFirst).toEqual(["pom.xml"]);
  expect(await second).toEqual(["settings.gradle"]);
});

test("allows a retry after a failed project-file scan", async () => {
  const coordinate = createProjectFileScanCoordinator<string[]>();
  const failedScan = deferred<string[]>();
  const failure = coordinate("C:/repo\0revision-1", () => failedScan.promise);
  failedScan.reject(new Error("scan failed"));
  await expect(failure).rejects.toThrow("scan failed");

  expect(await coordinate("C:/repo\0revision-1", async () => ["src/Main.java"])).toEqual([
    "src/Main.java",
  ]);
});
