import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type { GitDiff } from "../types/git.types";
import * as repository from "./git-repo-api";
import { getStashDiff, invalidateGitDiffData } from "./git-diff-api";

const root = "C:/fixture/stash-diff-identity";
const oldOid = "a".repeat(40);
const newOid = "b".repeat(40);
const oldDiff: GitDiff[] = [
  { file_path: "old.txt", is_new: true, is_deleted: false, is_renamed: false, lines: [] },
];
const newDiff: GitDiff[] = [
  { file_path: "new.txt", is_new: true, is_deleted: false, is_renamed: false, lines: [] },
];
const releases: Array<() => void> = [];
const reads: Array<Promise<unknown>> = [];
let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
let resolveRepository: ReturnType<typeof spyOn<typeof repository, "resolveRepositoryPath">>;

function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((release) => {
    resolve = release;
  });
  releases.push(() => resolve(fallback));
  return { promise, resolve };
}

function read(index: number, oid?: string) {
  const request = getStashDiff(root, index, oid);
  reads.push(request);
  return request;
}

beforeEach(() => {
  invalidateGitDiffData(root);
  resolveRepository = spyOn(repository, "resolveRepositoryPath").mockResolvedValue(root);
  invoke = spyOn(native, "invoke");
  invoke.mockClear();
});

afterEach(async () => {
  try {
    for (const release of releases.splice(0)) release();
    await Promise.allSettled(reads.splice(0));
  } finally {
    invoke.mockRestore();
    resolveRepository.mockRestore();
    invalidateGitDiffData(root);
  }
});

test("different stash OIDs at the same position keep their own in-flight diff and cache", async () => {
  const oldRead = deferred(oldDiff);
  const newRead = deferred(newDiff);
  invoke.mockImplementation((_command, args) => {
    const oid = (args as { stashOid: string }).stashOid;
    return (oid === oldOid ? oldRead.promise : newRead.promise) as Promise<never>;
  });
  const first = read(0, oldOid);
  const second = read(0, newOid);
  // Both calls have passed the mocked repository-resolution await; native reads remain gated.
  await Promise.resolve();
  expect(invoke).toHaveBeenCalledTimes(2);

  newRead.resolve(newDiff);
  expect(await second).toEqual(newDiff);
  oldRead.resolve(oldDiff);
  expect(await first).toEqual(oldDiff);
  expect(await read(0, newOid)).toEqual(newDiff);
  expect(invoke).toHaveBeenCalledTimes(2);
});

test("a retried old stash read cannot supply the new stash at its former position", async () => {
  const initialRead = deferred(oldDiff);
  const retriedRead = deferred(oldDiff);
  const retryStarted = deferred(undefined);
  const newRead = deferred(newDiff);
  let oldReads = 0;
  invoke.mockImplementation((_command, args) => {
    if ((args as { stashOid: string }).stashOid !== oldOid)
      return newRead.promise as Promise<never>;
    if (++oldReads === 1) return initialRead.promise as Promise<never>;
    retryStarted.resolve(undefined);
    return retriedRead.promise as Promise<never>;
  });
  const first = read(0, oldOid);
  await Promise.resolve();
  expect(invoke).toHaveBeenCalledTimes(1);
  emitGitChanged({ repoPath: root, scopes: ["stashes"], source: "stash-create" });
  initialRead.resolve(oldDiff);
  await retryStarted.promise;

  const second = read(0, newOid);
  await Promise.resolve();
  expect(invoke).toHaveBeenCalledTimes(3);
  newRead.resolve(newDiff);
  expect(await second).toEqual(newDiff);
  retriedRead.resolve(oldDiff);
  expect(await first).toEqual(oldDiff);
  expect(await read(0, newOid)).toEqual(newDiff);
});

test("legacy callers without an OID still share reads for the same stash position", async () => {
  const pending = deferred(oldDiff);
  invoke.mockImplementation(() => pending.promise as Promise<never>);
  const first = read(0);
  const second = read(0);
  await Promise.resolve();
  expect(invoke).toHaveBeenCalledTimes(1);
  expect(invoke).toHaveBeenCalledWith("git_stash_diff", { repoPath: root, stashIndex: 0 });
  pending.resolve(oldDiff);
  expect(await first).toEqual(oldDiff);
  expect(await second).toEqual(oldDiff);
});
