import { afterEach, expect, spyOn, test } from "bun:test";
import * as coreClient from "@/core/lithe-core-client";
import * as blameApi from "../api/git-blame-api";
import type { GitBlame } from "../types/git.types";
import { createGitBlameStore, getGitBlameCacheKey } from "./git-blame.store";

const REPO = "C:/work/repo";
const FILE = "C:/work/repo/src/App.java";

function blame(author: string): GitBlame {
  return {
    file_path: "src/App.java",
    lines: [
      {
        line_number: 1,
        total_lines: 1,
        commit_hash: author,
        is_uncommitted: false,
        author,
        email: `${author}@example.invalid`,
        time: 0,
        commit: author,
      },
    ],
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

const restorers: Array<() => void> = [];
afterEach(() => {
  for (const restore of restorers.splice(0)) restore();
});

test("a refresh keeps the shown blame until the new result replaces it", async () => {
  const pending = [deferred<blameApi.ResolvedGitBlame | null>(), deferred<blameApi.ResolvedGitBlame | null>()];
  let call = 0;
  const load = spyOn(blameApi, "getResolvedGitBlame").mockImplementation(() => pending[call++].promise);
  const cancel = spyOn(coreClient, "cancelCoreOperation").mockResolvedValue(true);
  restorers.push(() => load.mockRestore(), () => cancel.mockRestore());
  const store = createGitBlameStore();
  const key = getGitBlameCacheKey(REPO, FILE);
  const settle = (index: number, author: string) =>
    pending[index].resolve({ blame: blame(author), repoPath: REPO, filePath: "src/App.java" });

  // Initial load completes with the first author.
  const first = store.getState().actions.loadBlameForFile(REPO, FILE);
  settle(0, "ada");
  await first;
  expect(store.getState().blameData.get(key)?.lines[0].author).toBe("ada");

  // A cached file is not reloaded unless a refresh is requested.
  await store.getState().actions.loadBlameForFile(REPO, FILE);
  expect(load).toHaveBeenCalledTimes(1);

  // While the refresh runs, the previous annotation stays visible.
  const refresh = store.getState().actions.loadBlameForFile(REPO, FILE, { refresh: true });
  expect(store.getState().blameData.get(key)?.lines[0].author).toBe("ada");
  settle(1, "grace");
  await refresh;
  expect(store.getState().blameData.get(key)?.lines[0].author).toBe("grace");
  expect(load).toHaveBeenCalledTimes(2);
});

test("a newer refresh cancels the running one and ignores its late result", async () => {
  const pending = [deferred<blameApi.ResolvedGitBlame | null>(), deferred<blameApi.ResolvedGitBlame | null>()];
  let call = 0;
  const load = spyOn(blameApi, "getResolvedGitBlame").mockImplementation(() => pending[call++].promise);
  const cancel = spyOn(coreClient, "cancelCoreOperation").mockResolvedValue(true);
  restorers.push(() => load.mockRestore(), () => cancel.mockRestore());
  const store = createGitBlameStore();
  const key = getGitBlameCacheKey(REPO, FILE);

  const stale = store.getState().actions.loadBlameForFile(REPO, FILE, { refresh: true });
  const current = store.getState().actions.loadBlameForFile(REPO, FILE, { refresh: true });
  expect(cancel).toHaveBeenCalledTimes(1);

  pending[1].resolve({ blame: blame("grace"), repoPath: REPO, filePath: "src/App.java" });
  await current;
  pending[0].resolve({ blame: blame("ada"), repoPath: REPO, filePath: "src/App.java" });
  await stale;
  expect(store.getState().blameData.get(key)?.lines[0].author).toBe("grace");
});
