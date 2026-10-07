import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { GitCommit, GitReference } from "../types/git.types";
import { graphColorIdForName, javaStringHashCode } from "./git-graph-colors";
import {
  bestGraphReferenceLabel,
  layoutGitGraph,
  parseGitDecorations,
  type GitGraphLayout,
} from "./git-graph-layout";

const commit = (hash: string, parentHashes: string[] = [], decorations = ""): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes,
  message: hash,
  author: "Developer",
  date: "2026/08/16 10:00",
  decorations,
});

const colorIndexOfCommit = (layout: GitGraphLayout, hash: string): number | null => {
  const row = layout.rows.find((candidate) => candidate.commit.hash === hash);
  if (!row) throw new Error(`No graph row for ${hash}`);
  return row.colorIndex;
};

describe("Git graph layout", () => {
  for (const prefix of ["issue410", "issue410-date"]) {
    test(`repository-context graph matches the real IDEA ${prefix} oracle`, () => {
      const fixture = (name: string) =>
        readFileSync(
          new URL(
            `../../../../../../macos/Tests/LitheTests/Fixtures/GitGraph/${name}`,
            import.meta.url,
          ),
          "utf8",
        )
          .trim()
          .split(/\r?\n/);
      const readCommits = (name: string) =>
        fixture(name).map((line) => {
          const [hash, parents, decorations] = line.split("\t");
          return commit(
            hash,
            parents ? parents.split(" ") : [],
            decorations.trim().replace(/^\(|\)$/g, ""),
          );
        });
      const layout = layoutGitGraph(readCommits(`${prefix}-history.tsv`), undefined, {
        repositoryCommits: readCommits(`${prefix}-context.tsv`),
      });
      const actual = layout.rows
        .flatMap((row, index) => [
          `Node|${index}:${row.lane}:${row.colorIndex}`,
          ...row.printElements.map(
            (element) =>
              `Edge|${index}:${element.position}:${element.adjacentPosition}:${element.direction.toUpperCase()}:${element.hasArrow}:${element.isTerminal}:${element.isDotted ? "DASHED" : "SOLID"}:${element.colorIndex}`,
          ),
        ])
        .sort();
      const expected = fixture(
        prefix === "issue410" ? "issue410-context-idea.txt" : "issue410-date-idea.txt",
      )
        .filter((line) => !line.startsWith("Width|"))
        .map((line) => {
          const [kind, value] = line.split("|");
          const fields = value.split(":");
          return kind === "Node" ? `Node|${fields[0]}:${fields[1]}:${fields[3]}` : line;
        })
        .sort();
      expect(actual).toEqual(expected);
    });
  }

  test("branch scopes inherit repository colors and base order without replacing commit metadata", () => {
    const main = commit("main-tip", ["root"], "origin/main");
    const side = commit("side", ["root"], "HEAD -> feature");
    const root = commit("root");
    const context = [main, side, root];
    const full = layoutGitGraph(context);
    const scoped = layoutGitGraph([side, root], undefined, { repositoryCommits: context });
    expect(scoped.rows.map((row) => row.colorIndex)).toEqual(
      full.rows.slice(1).map((row) => row.colorIndex),
    );
    expect(scoped.rows[0].commit).toBe(side);
    expect(
      layoutGitGraph([side, main, root], undefined, { repositoryCommits: context }).rows.map(
        (row) => row.commit.hash,
      ),
    ).toEqual(["main-tip", "side", "root"]);
    expect(
      layoutGitGraph([side, root], new Set(["root"]), { repositoryCommits: context }).rows[0]
        .colorIndex,
    ).toBe(full.rows[2].colorIndex);
  });

  test("incomplete or duplicate repository context falls back without dropping visible commits", () => {
    const commits = [commit("tip", ["root"]), commit("root")];
    const expected = layoutGitGraph(commits);
    for (const context of [[commits[1]], [commits[0], commits[0], commits[1]]]) {
      expect(layoutGitGraph(commits, undefined, { repositoryCommits: context })).toEqual(expected);
    }
  });

  test("recognizes non-origin remote short names from actual reference metadata", () => {
    const remote: GitReference = {
      fullName: "refs/remotes/upstream/work",
      shortName: "upstream/work",
      kind: "remote",
      isCurrent: false,
      peelsToCommit: true,
    };
    const commits = [
      commit("local", ["root"], "main"),
      commit("remote", ["root"], "upstream/work"),
      commit("root"),
    ];
    const layout = layoutGitGraph(commits, undefined, { references: [remote] });
    expect(layout.rows[1].labels).toEqual([{ title: "upstream/work", kind: "remote" }]);
    expect(layout.rows[2].colorIndex).toBe(javaStringHashCode("upstream/work"));
    expect(layout.rows[0].colorIndex).toBe(javaStringHashCode("main"));
    expect(parseGitDecorations("team/local", new Set(["upstream/work"]))[0].kind).toBe("branch");
  });

  for (const span of [29, 30, 31, 999, 1_000]) {
    test(`compact and expanded long edges preserve topology and visible navigation endpoints at ${span} rows`, () => {
      const commits = Array.from({ length: span + 1 }, (_, row) =>
        commit(
          String(row),
          row === span ? [] : row === 0 ? ["1", String(span)] : [String(row + 1)],
        ),
      );
      for (const displayMode of ["compact", "expanded"] as const) {
        const layout = layoutGitGraph(commits, undefined, { displayMode });
        const arrows = layout.rows
          .flatMap((row) => row.printElements)
          .filter((element) => element.hasArrow);
        const expectedCount = span < 30 ? 0 : displayMode === "compact" || span < 1_000 ? 2 : 4;
        expect(arrows).toHaveLength(expectedCount);
        if (expectedCount)
          expect(new Set(arrows.map((element) => element.targetHash))).toEqual(
            new Set(["0", String(span)]),
          );
        expect(layout.rows).toHaveLength(commits.length);
        if (span >= 30)
          expect(layout.rows[Math.floor(span / 2)].laneCount).toBe(
            displayMode === "expanded" && span < 1_000 ? 2 : 1,
          );
        for (const [index, row] of layout.rows.entries()) {
          for (const element of row.printElements.filter((value) => !value.isTerminal)) {
            const neighbor = layout.rows[index + (element.direction === "down" ? 1 : -1)];
            expect(
              neighbor.printElements.some(
                (other) =>
                  other.id.replace(/:(up|down)$/, "") === element.id.replace(/:(up|down)$/, "") &&
                  other.direction !== element.direction &&
                  other.position === element.adjacentPosition &&
                  other.adjacentPosition === element.position &&
                  other.colorIndex === element.colorIndex,
              ),
            ).toBe(true);
          }
        }
      }
    });
  }

  test("unloaded parent arrows have no fabricated destination", () => {
    const layout = layoutGitGraph([commit("tip", ["unloaded"]), commit("other")]);
    const arrows = layout.rows
      .flatMap((row) => row.printElements)
      .filter((element) => element.hasArrow);
    expect(arrows).toHaveLength(1);
    expect(arrows[0].targetHash).toBeNull();
  });

  test("the unfiltered 200-commit graph matches the frozen IDEA positions, terminal markers and color identities", () => {
    const fixture = (name: string) =>
      readFileSync(
        new URL(
          `../../../../../../macos/Tests/LitheTests/Fixtures/GitGraph/${name}`,
          import.meta.url,
        ),
        "utf8",
      );
    const commits = fixture("issue410-history.tsv")
      .trim()
      .split(/\r?\n/)
      .map((line) => {
        const [hash, parents, decorations] = line.split("\t");
        return commit(
          hash,
          parents ? parents.split(" ") : [],
          decorations.trim().replace(/^\(|\)$/g, ""),
        );
      });
    const layout = layoutGitGraph(commits);
    const actual = layout.rows
      .flatMap((row, index) => [
        `Node|${index}:${row.lane}:${row.colorIndex}`,
        ...row.printElements.map(
          (element) =>
            `Edge|${index}:${element.position}:${element.adjacentPosition}:${element.direction.toUpperCase()}:${element.hasArrow}:${element.isTerminal}:${element.isDotted ? "DASHED" : "SOLID"}:${element.colorIndex}`,
        ),
      ])
      .sort();
    // Compare full signed upstream color IDs, with no palette normalization.
    const expected = fixture("issue410-idea.txt")
      .trim()
      .split(/\r?\n/)
      .filter((line) => !line.startsWith("Width|"))
      .map((line) => {
        const [kind, value] = line.split("|");
        const fields = value.split(":");
        if (kind === "Node") return `Node|${fields[0]}:${fields[1]}:${fields[3]}`;
        return `Edge|${fields.join(":")}`;
      })
      .sort();
    expect(actual).toEqual(expected);
  });

  test("unfiltered passing edges keep a shared midpoint while compact columns change", () => {
    const commits = [
      commit("0", ["1"], "HEAD -> main"),
      commit("1", ["3", "2"], "feature"),
      commit("2", ["3", "5"]),
      commit("3", ["5", "4"]),
      commit("4", ["5"]),
      commit("5"),
    ];
    const layout = layoutGitGraph(commits);
    const edge = layout.rows[2].parentEdges.find((candidate) => candidate.parentHash === "5")!;
    const down = layout.rows[3].printElements.find((element) => element.id === `${edge.id}:down`)!;
    const up = layout.rows[4].printElements.find((element) => element.id === `${edge.id}:up`)!;
    expect(down).toMatchObject({ position: 1, adjacentPosition: 2 });
    expect(up).toMatchObject({ position: 2, adjacentPosition: 1, colorIndex: down.colorIndex });
  });

  test("unfiltered merging half-edges retain each parent's color until the commit node", () => {
    const layout = layoutGitGraph([
      commit("merge", ["main", "side"], "HEAD -> main"),
      commit("main", ["root"]),
      commit("side", ["root"], "feature"),
      commit("root"),
    ]);
    const incoming = layout.rows[3].printElements.filter((element) => element.direction === "up");
    expect(incoming).toHaveLength(2);
    expect(new Set(incoming.map((element) => element.colorIndex)).size).toBe(2);
    expect(incoming.every((element) => element.position === layout.rows[3].lane)).toBe(true);
    for (const row of layout.rows.slice(1, 3)) {
      expect(
        incoming.find((element) => element.id === `${row.parentEdges[0].id}:up`)?.colorIndex,
      ).toBe(row.parentEdges[0].colorIndex);
    }
  });

  test("a last-row missing parent does not invent a continuation, and paging resolves it", () => {
    const page = layoutGitGraph([commit("head", ["older"])]);
    expect(page.hasMissingParents).toBe(true);
    expect(page.rows[0].printElements).toEqual([]);
    const complete = layoutGitGraph([commit("head", ["older"]), commit("older")]);
    expect(complete.hasMissingParents).toBe(false);
    expect(complete.rows[0].printElements).toHaveLength(1);
    expect(complete.rows[1].printElements).toHaveLength(1);
  });

  test("filtered half-edge positions and dashed styles match the pinned IntelliJ manyNodes fixture", () => {
    const fixture = (kind: "in" | "out") =>
      readFileSync(
        new URL(
          `../../../../../../macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/elementGenerator/manyNodes_${kind}.txt`,
          import.meta.url,
        ),
        "utf8",
      );
    const commits: GitCommit[] = [];
    const visible = new Set<string>();
    for (const line of fixture("in").trim().split(/\r?\n/)) {
      const [node, targets] = line.split("|-");
      const id = node.split("_")[0];
      visible.add(id);
      const hidden: GitCommit[] = [];
      const parents = targets
        .split(" ")
        .filter(Boolean)
        .map((target) => {
          const [hash, style] = target.split("_");
          if (style !== "D") return hash;
          const hiddenHash = `hidden-${id}-${hash}`;
          hidden.push(commit(hiddenHash, [hash]));
          return hiddenHash;
        });
      commits.push(commit(id, parents), ...hidden);
    }
    // This upstream case has no >=7-row edges, so its custom threshold and
    // our 30-row compact threshold produce the same print elements.
    const layout = layoutGitGraph(commits, visible);
    const actual = layout.rows
      .flatMap((row, index) => [
        `Node|${index}:${row.lane}`,
        ...row.printElements!.map(
          (segment) =>
            `Edge:${segment.direction.toUpperCase()}:${segment.isDotted ? "DASHED" : "SOLID"}|${index}:${segment.position}:${segment.adjacentPosition}`,
        ),
      ])
      .sort();
    const expected = fixture("out")
      .trim()
      .split(/\r?\n/)
      .map((line) => {
        const [element, position] = line.trim().split("|-");
        return `${element}|${position}`;
      })
      .sort();
    expect(actual).toEqual(expected);
  });

  test("projects hidden linear ancestors as dotted edges without changing permanent colors", () => {
    const commits = [
      commit("a", ["b"], "HEAD -> feature"),
      commit("b", ["c"], "origin/main"),
      commit("c", ["d"]),
      commit("d"),
    ];
    const full = layoutGitGraph(commits);
    const filtered = layoutGitGraph(commits, new Set(["a", "d"]));
    expect(filtered.rows.map((row) => row.commit.hash)).toEqual(["a", "d"]);
    expect(filtered.rows[0].parentEdges).toMatchObject([
      { parentHash: "d", isDotted: true, isMissing: false },
    ]);
    expect(filtered.hasMissingParents).toBe(false);
    for (const row of filtered.rows) {
      expect(row.colorIndex).toBe(
        full.rows.find((candidate) => candidate.commit.hash === row.commit.hash)!.colorIndex,
      );
      expect(row.printElements?.every((segment) => segment.isDotted)).toBe(true);
    }
    // Clearing a query recovers the original unfiltered graph and commit objects.
    expect(layoutGitGraph(commits)).toEqual(full);
    expect(filtered.rows[0].commit).toBe(commits[0]);
  });

  test("preserves direct and hidden merge parents as distinct solid and dotted connections", () => {
    const commits = [
      commit("merge", ["left", "hidden"], "HEAD -> main"),
      commit("left", ["root"]),
      commit("hidden", ["right"]),
      commit("right", ["root"]),
      commit("root"),
    ];
    const filtered = layoutGitGraph(commits, new Set(["merge", "left", "right"]));
    expect(
      filtered.rows[0].parentEdges.map(({ parentHash, isDotted }) => ({ parentHash, isDotted })),
    ).toEqual([
      { parentHash: "left", isDotted: false },
      { parentHash: "right", isDotted: true },
    ]);
    expect(filtered.rows.slice(1).every((row) => row.parentEdges.length === 0)).toBe(true);
    expect(filtered.hasMissingParents).toBe(false);
    // Every nonterminal half connects to the same edge, color and midpoint in
    // the next visible row, even while compact columns shift at a merge.
    for (let row = 0; row < filtered.rows.length - 1; row += 1) {
      for (const down of filtered.rows[row].printElements!.filter(
        (segment) => segment.direction === "down",
      )) {
        const up = filtered.rows[row + 1].printElements!.find(
          (segment) => segment.id === down.id.replace(/:down$/, ":up"),
        );
        expect(up).toBeDefined();
        expect(up).toMatchObject({
          position: down.adjacentPosition,
          adjacentPosition: down.position,
          colorIndex: down.colorIndex,
          isDotted: down.isDotted,
        });
      }
    }
  });

  test("a direct parent wins over duplicate hidden paths to the same visible ancestor", () => {
    const filtered = layoutGitGraph(
      [commit("a", ["hidden", "root", "root"]), commit("hidden", ["root"]), commit("root")],
      new Set(["a", "root"]),
    );
    expect(filtered.rows[0].parentEdges).toMatchObject([{ parentHash: "root", isDotted: false }]);
    expect(filtered.rows[0].parentEdges).toHaveLength(1);
  });

  test("does not connect unrelated visible commits or treat a hidden loaded root as missing", () => {
    const filtered = layoutGitGraph(
      [commit("a", ["hidden"]), commit("unrelated"), commit("hidden", ["root"]), commit("root")],
      new Set(["a", "unrelated"]),
    );
    expect(
      filtered.rows.every((row) => row.parentEdges.length === 0 && row.printElements?.length === 0),
    ).toBe(true);
    expect(filtered.hasMissingParents).toBe(false);
  });

  test("projects unloaded parents through hidden ancestors and resolves them when paging", () => {
    const page = [commit("a", ["hidden"]), commit("hidden", ["older"]), commit("unrelated")];
    const filtered = layoutGitGraph(page, new Set(["a", "unrelated"]));
    expect(filtered.rows[0].parentEdges).toMatchObject([
      { parentHash: "older", isMissing: true, isDotted: true },
    ]);
    expect(filtered.hasMissingParents).toBe(true);
    expect(
      filtered.rows
        .flatMap((row) => row.printElements ?? [])
        .every((segment) => segment.isDotted && segment.isMissing),
    ).toBe(true);
    const loaded = layoutGitGraph([...page, commit("older")], new Set(["a", "older"]));
    expect(loaded.hasMissingParents).toBe(false);
    expect(loaded.rows[0].parentEdges).toMatchObject([
      { parentHash: "older", isMissing: false, isDotted: true },
    ]);
  });

  test("deduplicates hidden missing merge paths and stops boundary propagation at visible parents", () => {
    const filtered = layoutGitGraph(
      [
        commit("a", ["left", "right", "missing", "missing"]),
        commit("left", ["missing", "missing"]),
        commit("right", ["missing", "other"]),
      ],
      new Set(["a"]),
    );
    expect(
      filtered.rows[0].parentEdges.map(({ parentHash, isDotted }) => ({ parentHash, isDotted })),
    ).toEqual([
      { parentHash: "missing", isDotted: false },
      { parentHash: "other", isDotted: true },
    ]);
    const stopped = layoutGitGraph(
      [commit("a", ["b"]), commit("b", ["hidden"]), commit("hidden", ["missing"])],
      new Set(["a", "b"]),
    );
    expect(stopped.rows[0].parentEdges).toMatchObject([
      { parentHash: "b", isMissing: false, isDotted: false },
    ]);
    expect(stopped.rows[1].parentEdges).toMatchObject([
      { parentHash: "missing", isMissing: true, isDotted: true },
    ]);
  });

  test("an empty match set produces no graph or missing-history marker", () => {
    expect(layoutGitGraph([commit("a", ["missing"])], new Set())).toEqual({
      rows: [],
      laneCount: 0,
      hasMissingParents: false,
    });
  });

  test("projects 5,000 hidden merge boundaries without retaining ancestor sets per commit", () => {
    const count = 5_000;
    const commits = Array.from({ length: count }, (_, row) =>
      commit(
        String(row),
        row + 1 < count ? [String(row + 1), `missing-${row}`] : [`missing-${row}`],
      ),
    );
    const filtered = layoutGitGraph(commits, new Set(["0"]));
    expect(filtered.rows).toHaveLength(1);
    expect(new Set(filtered.rows[0].parentEdges.map((edge) => edge.parentHash))).toEqual(
      new Set(Array.from({ length: count }, (_, row) => `missing-${row}`)),
    );
    expect(filtered.hasMissingParents).toBe(true);
  });

  test("keeps a linear history in one fixed lane", () => {
    const layout = layoutGitGraph([
      commit("three", ["two"]),
      commit("two", ["one"]),
      commit("one"),
    ]);

    expect(layout.laneCount).toBe(1);
    expect(layout.rows.map((row) => row.lane)).toEqual([0, 0, 0]);
    expect(layout.hasMissingParents).toBe(false);
  });

  test("opens a stable secondary lane for a merge parent", () => {
    const layout = layoutGitGraph([
      commit("merge", ["feature", "root"], "HEAD -> main"),
      commit("feature", ["root"], "feature/orders"),
      commit("root"),
    ]);

    expect(layout.rows[0].parentEdges).toHaveLength(2);
    expect(new Set(layout.rows[0].parentEdges.map((edge) => edge.targetLane)).size).toBe(2);
    expect(layout.rows[1].parentEdges[0].targetLane).not.toBeNull();
    expect(layout.laneCount).toBeGreaterThan(1);
    expect(layout.hasMissingParents).toBe(false);
  });

  test("starts a branch tip lane at its node instead of above it", () => {
    // Regression: the newest commit drew a lane segment above its node with nothing above it.
    const layout = layoutGitGraph([
      commit("tip", ["base"], "HEAD -> feature"),
      commit("base", ["root"]),
      commit("side", ["root"], "main"),
      commit("root"),
    ]);

    expect(layout.rows[0].incomingLaneColors[layout.rows[0].lane]).toBeNull();
    expect(layout.rows[1].incomingLaneColors[layout.rows[1].lane]).toBe(layout.rows[1].colorIndex);
    const side = layout.rows[2];
    expect(side.incomingLaneColors[side.lane]).toBeNull();
    // Lanes of other branches passing through the tip row are still drawn.
    expect(
      side.incomingLaneColors.some((color, lane) => lane !== side.lane && color !== null),
    ).toBe(true);
    // The node keeps its own lane color even though its lane has no incoming segment.
    expect(side.colorIndex).not.toBe(layout.rows[1].colorIndex);
  });

  test("marks parents outside the cumulative snapshot as missing", () => {
    const layout = layoutGitGraph([commit("visible", ["not-loaded"])]);

    expect(layout.hasMissingParents).toBe(true);
    expect(layout.rows[0].parentEdges[0]).toMatchObject({ targetLane: null, isMissing: true });
  });

  test("parses head, branch, remote, and tag decorations", () => {
    expect(parseGitDecorations("HEAD -> main, origin/main, tag: v1.0.0")).toEqual([
      { title: "HEAD", kind: "head" },
      { title: "main", kind: "branch" },
      { title: "origin/main", kind: "remote" },
      { title: "v1.0.0", kind: "tag" },
    ]);
  });

  test("keeps branch fragments distinct when topology moves them to another lane", () => {
    const featureTipInFirstLane = layoutGitGraph([
      commit("tip", ["root"], "feature/orders"),
      commit("root"),
    ]);
    const featureAsSecondParent = layoutGitGraph([
      commit("merge", ["root", "tip"], "HEAD -> main"),
      commit("tip", ["root"], "feature/orders"),
      commit("root"),
    ]);

    expect(colorIndexOfCommit(featureTipInFirstLane, "tip")).toBe(
      graphColorIdForName("feature/orders"),
    );
    // Once the feature is a secondary parent of the main head, IntelliJ's
    // permanent layout gives that side fragment its layout color rather than
    // treating it as a new graph head. It must still remain distinct from
    // the main fragment.
    expect(featureAsSecondParent.rows[1].lane).toBe(1);
    expect(colorIndexOfCommit(featureAsSecondParent, "tip")).not.toBe(
      colorIndexOfCommit(featureAsSecondParent, "merge"),
    );
    expect(colorIndexOfCommit(featureAsSecondParent, "tip")).not.toBe(
      colorIndexOfCommit(featureAsSecondParent, "root"),
    );
  });

  test("keeps a local head visually distinct from a decorated parent branch", () => {
    const layout = layoutGitGraph([
      commit("local", ["base"], "HEAD -> feature/orders"),
      commit("base", ["root"], "origin/main"),
      commit("root"),
    ]);

    expect(colorIndexOfCommit(layout, "local")).toBe(graphColorIdForName("feature/orders"));
    expect(colorIndexOfCommit(layout, "base")).toBe(graphColorIdForName("origin/main"));
    expect(colorIndexOfCommit(layout, "local")).not.toBe(colorIndexOfCommit(layout, "base"));
  });

  test("gives unreferenced lanes a deterministic color", () => {
    const commits = [commit("a", ["b", "c"]), commit("b", ["d"]), commit("c", ["d"]), commit("d")];
    const first = layoutGitGraph(commits);
    const second = layoutGitGraph(commits);

    expect(colorIndexOfCommit(first, "a")).toBe(0);
    expect(colorIndexOfCommit(first, "c")).toBe(2);
    expect(first.rows.map((row) => row.incomingLaneColors)).toEqual(
      second.rows.map((row) => row.incomingLaneColors),
    );
  });

  test("maps reference names through Java String.hashCode", () => {
    expect(javaStringHashCode("main")).toBe(3343801);
    expect(graphColorIdForName("main")).toBe(3343801);
    expect(graphColorIdForName("feature/orders")).toBe(javaStringHashCode("feature/orders"));
  });

  test("prefers the most significant reference for the color identity", () => {
    expect(
      bestGraphReferenceLabel(parseGitDecorations("HEAD -> main, origin/main, tag: v1")),
    ).toMatchObject({ title: "origin/main" });
    expect(
      bestGraphReferenceLabel(parseGitDecorations("HEAD -> feature/orders, hotfix")),
    ).toMatchObject({ title: "feature/orders" });
    expect(bestGraphReferenceLabel([])).toBeNull();
  });
});
