import * as native from "@/platform/tauri-core";
import { spyOn } from "bun:test";
import fixture from "../../../../shared/fixtures/git/graph-projection-v1.json";
import {
  attachGitGraphCommits,
  type GitGraphLabel,
  type GitGraphLayout,
  type GitGraphProjection,
  type GitGraphProjectionRequest,
} from "@/features/git/api/git-graph-projection-api";
import type { GitCommit } from "@/features/git/types/git.types";

type FixtureCase = { name: string; request: unknown; response: GitGraphProjection };
const cases = fixture.cases as unknown as FixtureCase[];

type NormalizedCommit = { hash: string; parentHashes: string[]; decorations: string };
type NormalizedRequest = {
  commits: NormalizedCommit[];
  remoteNames: string[];
  repositoryCommits: NormalizedCommit[];
  visibleHashes: string[] | null;
  displayMode: string;
  currentBranch: string | null;
};

const commitOf = (value: Record<string, any>): NormalizedCommit => ({
  hash: value.hash,
  parentHashes: value.parentHashes ?? [],
  decorations: value.decorations ?? "",
});

/** Fills every default Core applies, so equal requests compare equal as JSON. */
export function normalizeGraphRequest(request: Record<string, any>): NormalizedRequest {
  return {
    commits: request.commits.map(commitOf),
    remoteNames: request.remoteNames ?? [],
    repositoryCommits: (request.repositoryCommits ?? []).map(commitOf),
    visibleHashes: request.visibleHashes ?? null,
    displayMode: request.displayMode ?? "compact",
    currentBranch: request.currentBranch ?? null,
  };
}

const key = (request: Record<string, any>) => JSON.stringify(normalizeGraphRequest(request));
const byRequest = new Map(cases.map((value) => [key(value.request as Record<string, any>), value]));

/** The shared-fixture case Core's response is defined by, when the request is one of them. */
export function graphFixtureCase(name: string): FixtureCase {
  const found = cases.find((value) => value.name === name);
  if (!found) throw new Error(`No graph projection fixture named ${name}`);
  return found;
}

/** Commits of a fixture case, as the host would hold them. */
export function graphFixtureCommits(name: string): GitCommit[] {
  return normalizeGraphRequest(graphFixtureCase(name).request as Record<string, any>).commits.map(
    (commit) => ({
      ...commit,
      shortHash: commit.hash,
      message: commit.hash,
      author: "Fixture",
      date: "unknown",
    }),
  );
}

/** The layout Core returns for a fixture case, with the fixture commits attached. */
export function graphFixtureLayout(name: string): GitGraphLayout {
  return attachGitGraphCommits(graphFixtureCommits(name), graphFixtureCase(name).response);
}

function parseLabels(decorations: string, remoteNames: ReadonlySet<string>): GitGraphLabel[] {
  const label = (title: string, kind: GitGraphLabel["kind"]) => ({ id: `${kind}:${title}`, title, kind });
  const local = (name: string) => name.replace(/^refs\/heads\//, "");
  return decorations.split(",").flatMap((value): GitGraphLabel[] => {
    const raw = value.trim();
    if (!raw) return [];
    if (raw === "HEAD") return [label("HEAD", "head")];
    if (raw.startsWith("HEAD -> ")) {
      return [label("HEAD", "head"), label(local(raw.slice("HEAD -> ".length)), "branch")];
    }
    if (raw.startsWith("tag: ")) return [label(raw.slice("tag: ".length), "tag")];
    if (raw.startsWith("refs/tags/")) return [label(raw.slice("refs/tags/".length), "tag")];
    if (remoteNames.has(raw) || raw.startsWith("origin/") || raw.startsWith("refs/remotes/")) {
      return [label(raw.replace(/^refs\/remotes\//, ""), "remote")];
    }
    return [label(local(raw), "branch")];
  });
}

/**
 * Rows and labels only, with no routing: one lane, color zero, no edges. Table behavior tests
 * that do not assert geometry use it for histories that are not in the shared fixture.
 * First occurrences win and `visibleHashes` filters, as in Core.
 */
export function geometryFreeProjection(request: NormalizedRequest): GitGraphProjection {
  const remoteNames = new Set(request.remoteNames);
  const visible = request.visibleHashes ? new Set(request.visibleHashes) : null;
  const seen = new Set<string>();
  const rows = request.commits
    .filter((commit) => {
      if (seen.has(commit.hash)) return false;
      seen.add(commit.hash);
      return !visible || visible.has(commit.hash);
    })
    .map((commit) => ({
      commitHash: commit.hash,
      lane: 0,
      laneCount: 1,
      colorId: 0,
      layoutIndex: 1,
      incomingLaneColors: [0],
      parentEdges: [],
      labels: parseLabels(commit.decorations, remoteNames),
      printElements: [],
    }));
  const hashes = new Map<string, NormalizedCommit>();
  for (const commit of [...request.commits, ...request.repositoryCommits]) {
    if (!hashes.has(commit.hash)) hashes.set(commit.hash, commit);
  }
  const head = request.currentBranch
    ? [...hashes.values()].find((commit) =>
        parseLabels(commit.decorations, new Set()).some(
          (label) => label.kind === "branch" && label.title === request.currentBranch,
        ),
      )
    : undefined;
  const reached = new Set<string>();
  const pending = head ? [head.hash] : [];
  while (pending.length) {
    const hash = pending.pop()!;
    if (reached.has(hash)) continue;
    reached.add(hash);
    pending.push(...(hashes.get(hash)?.parentHashes ?? []));
  }
  return {
    version: 1,
    rows,
    laneCount: rows.length ? 1 : 0,
    recommendedLaneCount: rows.length ? 1 : 0,
    hasMissingParents: false,
    currentBranchHashes: [...reached].sort(),
  };
}

/**
 * A long undecorated linear history (each commit's only parent is the next row) is one
 * lane of color zero. `projects a linear chain` in the stub test pins it to the fixture.
 */
export function linearChainProjection(request: NormalizedRequest): GitGraphProjection | null {
  const { commits } = request;
  if (request.visibleHashes || request.currentBranch) return null;
  const linear = commits.every(
    (commit, row) =>
      commit.decorations === "" &&
      (row + 1 < commits.length
        ? commit.parentHashes.length === 1 && commit.parentHashes[0] === commits[row + 1].hash
        : commit.parentHashes.length === 0),
  );
  if (!linear || new Set(commits.map((commit) => commit.hash)).size !== commits.length) return null;
  const element = (row: number, direction: "up" | "down") => {
    const edge = direction === "down" ? row : row - 1;
    return {
      id: `${edge}:${edge + 1}:false:${direction}`,
      position: 0,
      adjacentPosition: 0,
      direction,
      colorId: 0,
      isDotted: false,
      isMissing: false,
      hasArrow: false,
      isTerminal: false,
      targetHash: commits[direction === "down" ? row + 1 : row - 1].hash,
    };
  };
  return {
    version: 1,
    rows: commits.map((commit, row) => ({
      commitHash: commit.hash,
      lane: 0,
      laneCount: 1,
      colorId: 0,
      layoutIndex: 1,
      incomingLaneColors: [0],
      parentEdges:
        row + 1 < commits.length
          ? [
              {
                id: `${row}:${row + 1}:false`,
                parentHash: commits[row + 1].hash,
                targetLane: 0,
                colorId: 0,
                isMissing: false,
                isDotted: false,
              },
            ]
          : [],
      labels: [],
      printElements: [
        ...(row > 0 ? [element(row, "up")] : []),
        ...(row + 1 < commits.length ? [element(row, "down")] : []),
      ],
    })),
    laneCount: 1,
    recommendedLaneCount: commits.length > 0 ? 1 : 0,
    hasMissingParents: false,
    currentBranchHashes: [],
  };
}

export interface GitGraphProjectionStubOptions {
  /**
   * Accept histories that are not in the shared fixture and project them without routing.
   * Only for tests that do not assert graph geometry.
   */
  geometryFree?: boolean;
}

/**
 * Stand-in for Core's `git.graphProjection` in Git Log tests. Core owns the layout rules
 * (`git/graph.rs`); this stub never routes a graph itself. It answers a request that is in
 * `shared/fixtures/git/graph-projection-v1.json` with Core's recorded response, projects an
 * undecorated linear chain, and otherwise either fails loudly or, when `geometryFree`
 * is set, returns rows and labels without geometry. `git-graph-projection-stub.test.ts`
 * replays the fixture through it so it cannot drift.
 */
export function stubGitGraphProjection(
  request: Record<string, any>,
  options: GitGraphProjectionStubOptions = {},
): GitGraphProjection {
  const normalized = normalizeGraphRequest(request);
  const recorded = byRequest.get(JSON.stringify(normalized));
  if (recorded) return recorded.response;
  if (normalized.visibleHashes?.length === 0) return geometryFreeProjection(normalized);
  const chain = linearChainProjection(normalized);
  if (chain) return chain;
  if (options.geometryFree) return geometryFreeProjection(normalized);
  throw new Error(
    "git.graphProjection stub: this history is not in the shared fixture; add a case to graph-projection-v1.json or pass geometryFree",
  );
}

/** Routes `git.graphProjection` to the stub; other Core commands keep their behavior. */
export function installGitGraphProjectionStub(options: GitGraphProjectionStubOptions = {}) {
  const original = native.invoke;
  return spyOn(native, "invoke").mockImplementation((async (command: string, payload?: unknown) =>
    command === "git.graphProjection"
      ? stubGitGraphProjection(payload as Record<string, unknown>, options)
      : original(command, payload as Record<string, unknown>)) as typeof native.invoke);
}

export type { GitGraphProjectionRequest };
