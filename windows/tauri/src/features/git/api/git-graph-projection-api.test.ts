import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/git/graph-projection-v1.json";
import {
  graphFixtureCommits,
  installGitGraphProjectionStub,
  normalizeGraphRequest,
} from "@/test-utils/git-graph-projection-stub";
import type { GitReference } from "../types/git.types";
import {
  attachGitGraphCommits,
  buildGitGraphRequest,
  layoutGitGraph,
  type GitGraphProjection,
} from "./git-graph-projection-api";

const cases = fixture.cases as unknown as Array<{
  name: string;
  request: Record<string, any>;
  response: { rows: Array<{ commitHash: string }>; currentBranchHashes: string[] };
}>;
let spy: ReturnType<typeof installGitGraphProjectionStub>;

beforeEach(() => {
  spy = installGitGraphProjectionStub();
});
afterEach(() => spy.mockRestore());

const remote = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  isCurrent: false,
  peelsToCommit: true,
});

/** The host-side inputs a fixture case stands for. */
function inputsOf(request: Record<string, any>) {
  const normalized = normalizeGraphRequest(request);
  const asCommit = (commit: (typeof normalized.commits)[number]) => ({
    ...commit,
    shortHash: commit.hash,
    message: commit.hash,
    author: "Fixture",
    date: "unknown",
  });
  return {
    commits: normalized.commits.map(asCommit),
    visibleHashes: normalized.visibleHashes ?? undefined,
    options: {
      references: normalized.remoteNames.map(remote),
      repositoryCommits: normalized.repositoryCommits.map(asCommit),
      displayMode: normalized.displayMode as "compact" | "expanded",
      currentBranch: normalized.currentBranch ?? undefined,
    },
  };
}

test("the request built from host inputs is the fixture request for every case", () => {
  for (const testCase of cases) {
    const { commits, visibleHashes, options } = inputsOf(testCase.request);
    expect(
      normalizeGraphRequest(buildGitGraphRequest(commits, visibleHashes, options)),
      testCase.name,
    ).toEqual(normalizeGraphRequest(testCase.request));
  }
});

test("rows carry Core's projection and the caller's first commit for each hash", async () => {
  for (const testCase of cases) {
    const { commits, visibleHashes, options } = inputsOf(testCase.request);
    const layout = await layoutGitGraph(commits, visibleHashes, options);
    expect(layout.rows.map((row) => row.commitHash), testCase.name).toEqual(
      testCase.response.rows.map((row) => row.commitHash),
    );
    for (const row of layout.rows) {
      expect(row.commit).toBe(commits.find((commit) => commit.hash === row.commitHash)!);
    }
    expect([...layout.currentBranchHashes].sort()).toEqual(testCase.response.currentBranchHashes);
  }
});

test("a window is projected in one call, never once per commit", async () => {
  const commits = graphFixtureCommits("compactLongEdge");
  expect(commits.length).toBeGreaterThan(30);
  const layout = await layoutGitGraph(commits);
  expect(layout.rows).toHaveLength(commits.length);
  expect(spy.mock.calls.filter(([command]) => command === "git.graphProjection")).toHaveLength(1);
});

test("an empty window skips Core", async () => {
  const layout = await layoutGitGraph([]);
  expect(layout.rows).toEqual([]);
  expect(spy.mock.calls).toHaveLength(0);
});

test("an unknown commit in Core's answer is an error, not a fabricated row", async () => {
  spy.mockRestore();
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({
    version: 1,
    // A Core answer always carries both edge collections, even for a bare row.
    rows: [{ commitHash: "ghost", parentEdges: [], printElements: [] }],
    laneCount: 1,
    recommendedLaneCount: 1,
    hasMissingParents: false,
    currentBranchHashes: [],
  })) as unknown as typeof native.invoke);
  try {
    await expect(layoutGitGraph(graphFixtureCommits("linearHistory"))).rejects.toThrow("ghost");
  } finally {
    invoke.mockRestore();
    spy = installGitGraphProjectionStub();
  }
});

test("unloaded-parent arrows name their parent even when the arrow sits on the next row", () => {
  const base = graphFixtureCommits("linearHistory")[0];
  const commits = [
    { ...base, hash: "tip", shortHash: "tip", parentHashes: ["unloaded"], decorations: "" },
    { ...base, hash: "other", shortHash: "other", parentHashes: [], decorations: "" },
  ];
  const projection: GitGraphProjection = {
    version: 1,
    laneCount: 1,
    recommendedLaneCount: 1,
    hasMissingParents: true,
    currentBranchHashes: [],
    rows: [
      {
        commitHash: "tip",
        lane: 0,
        laneCount: 1,
        colorId: 0,
        layoutIndex: 1,
        incomingLaneColors: [0],
        labels: [],
        printElements: [],
        parentEdges: [
          {
            id: "0:unloaded:false",
            parentHash: "unloaded",
            targetLane: null,
            colorId: 0,
            isMissing: true,
            isDotted: false,
          },
        ],
      },
      {
        commitHash: "other",
        lane: 0,
        laneCount: 1,
        colorId: 0,
        layoutIndex: 1,
        incomingLaneColors: [0],
        labels: [],
        parentEdges: [],
        printElements: [
          {
            id: "0:unloaded:false:down",
            position: 0,
            adjacentPosition: 0,
            direction: "down",
            colorId: 0,
            isDotted: false,
            isMissing: true,
            hasArrow: true,
            isTerminal: true,
            targetHash: null,
          },
        ],
      },
    ],
  };
  const layout = attachGitGraphCommits(commits, projection);
  expect(layout.rows[1].printElements[0].targetHash).toBe("unloaded");
  expect(layout.rows[0].printElements).toEqual([]);
});
