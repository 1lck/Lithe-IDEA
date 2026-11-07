import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import * as searchApi from "@/features/file-search/lib/file-search-api";
import * as rankApi from "@/features/file-search/lib/rank-names";
import { useRecentFilesStore } from "@/features/file-system/stores/recent-files.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { CategorizedFiles } from "../types/quick-open.types";
import { useFileSearch } from "./use-file-search";

const target = {
  name: "independent-commit-diff.ts",
  path: "D:/fixture/project/src/independent-commit-diff.ts",
  isDir: false,
};
const other = { name: "other.ts", path: "D:/fixture/project/src/other.ts", isDir: false };
const gitignore = { name: ".gitignore", path: "D:/fixture/project/.gitignore", isDir: false };
const files = [target, other, gitignore];

const hit = (index: number, tier: rankApi.RankTier = "other"): rankApi.RankedName => ({
  index,
  degree: 1000,
  tier,
  nameMatchRanges: [],
});

let restoreDom: () => void;
let host: HTMLDivElement;
let root: Root;
let previousAct: boolean | undefined;
let previousBuffers: ReturnType<typeof useBufferStore.getState>;
let previousRecent: ReturnType<typeof useRecentFilesStore.getState>["recentFiles"];
let results: CategorizedFiles | undefined;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

function Probe({
  query,
  list = files,
  native = [],
}: {
  query: string;
  list?: typeof files;
  native?: string[];
}) {
  results = useFileSearch(list, query, {
    hasLoadedFiles: true,
    rootFolderPath: "D:/fixture/project",
    nativeRootPaths: native,
  });
  return null;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousBuffers = useBufferStore.getState();
  previousRecent = useRecentFilesStore.getState().recentFiles;
  useBufferStore.setState({
    buffers: [createPaneContent("active", { type: "editor", ...target, content: "" })],
    activeBufferId: "active",
  });
  useRecentFilesStore.setState({ recentFiles: [] });
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  results = undefined;
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    host.remove();
    useBufferStore.setState(previousBuffers);
    useRecentFilesStore.setState({ recentFiles: previousRecent });
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

test("a typed query sends the active editor as explicit open context; the empty switcher excludes it", async () => {
  const rank = spyOn(rankApi, "rankNames").mockResolvedValue([hit(0, "open")]);
  try {
    await act(async () => root.render(<Probe query="independent-commit-diff" />));
    expect(rank).toHaveBeenCalledTimes(1);
    const [query, candidates, context] = rank.mock.calls[0]!;
    expect(query).toBe("independent-commit-diff");
    expect(candidates.map((candidate) => candidate.path)).toEqual(files.map((file) => file.path));
    expect(context).toEqual({ openPaths: [target.path], recentPaths: [] });
    expect(results?.openBufferFiles.map((file) => file.path)).toEqual([target.path]);

    await act(async () => root.render(<Probe query="" />));
    expect(results?.openBufferFiles).toEqual([]);
    expect(results?.otherFiles.map((file) => file.path)).toEqual([other.path]);
    expect(rank).toHaveBeenCalledTimes(1);
  } finally {
    rank.mockRestore();
  }
});

test("typed queries rank the full snapshot, so switcher-ignored files are reachable", async () => {
  const rank = spyOn(rankApi, "rankNames").mockResolvedValue([hit(2)]);
  try {
    await act(async () => root.render(<Probe query=".gitignore" />));
    expect(results?.otherFiles.map((file) => file.path)).toEqual([gitignore.path]);
    await act(async () => root.render(<Probe query="" />));
    expect(results?.otherFiles.map((file) => file.path)).not.toContain(gitignore.path);
    expect(results?.recentFilesInResults).toEqual([]);
  } finally {
    rank.mockRestore();
  }
});

test("identical requests are issued once, stale answers are dropped, and the list is kept while loading", async () => {
  const pending: Array<(hits: rankApi.RankedName[]) => void> = [];
  const rank = spyOn(rankApi, "rankNames").mockImplementation(
    () => new Promise((resolve) => pending.push(resolve)),
  );
  try {
    await act(async () => root.render(<Probe query="oth" />));
    await act(async () => root.render(<Probe query="oth" />));
    expect(rank).toHaveBeenCalledTimes(1);
    await act(async () => pending[0]!([hit(1)]));
    expect(results?.otherFiles.map((file) => file.path)).toEqual([other.path]);

    // The next query is slow: the earlier list stays on screen instead of flashing empty.
    await act(async () => root.render(<Probe query="othe" />));
    expect(rank).toHaveBeenCalledTimes(2);
    expect(results?.otherFiles.map((file) => file.path)).toEqual([other.path]);

    // A third query overtakes the second; the second answer arrives late and must be ignored.
    await act(async () => root.render(<Probe query="other" />));
    await act(async () => pending[2]!([hit(2)]));
    await act(async () => pending[1]!([hit(1)]));
    expect(results?.otherFiles.map((file) => file.path)).toEqual([gitignore.path]);
  } finally {
    rank.mockRestore();
  }
});

test("local roots query Core's name index with the context and never send the inventory back", async () => {
  const rank = spyOn(rankApi, "rankNames");
  const search = spyOn(searchApi, "searchFileNames").mockResolvedValue([
    { ...target, relative_path: "src/independent-commit-diff.ts", score: 2048 },
    { ...other, relative_path: "src/other.ts", score: 1024 },
  ]);
  try {
    await act(async () => root.render(<Probe query="o" native={["D:/fixture/project"]} />));
    expect(rank).not.toHaveBeenCalled();
    expect(search).toHaveBeenCalledTimes(1);
    const [query, roots, , , context] = search.mock.calls[0]!;
    expect(query).toBe("o");
    expect(roots).toEqual(["D:/fixture/project"]);
    expect(context).toEqual({ openPaths: [target.path], recentPaths: [] });
    // Core's order is kept; the active editor is the open section, the rest are other files.
    expect(results?.openBufferFiles.map((file) => file.path)).toEqual([target.path]);
    expect(results?.otherFiles.map((file) => file.path)).toEqual([other.path]);
  } finally {
    rank.mockRestore();
    search.mockRestore();
  }
});
