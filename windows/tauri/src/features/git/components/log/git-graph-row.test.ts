import { describe, expect, test } from "bun:test";
import { GitGraphRow } from "./git-graph-row";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { layoutGitGraph } from "../../utils/git-graph-layout";
import type { GitCommit } from "../../types/git.types";
import { graphColor } from "../../utils/git-graph-colors";
import { gitGraphPaintMetrics } from "../../utils/git-graph-geometry";

describe("git graph decoration labels", () => {
  test("subject and references use each row's graph extent within a shared recommended baseline", () => {
    const commits: GitCommit[] = Array.from({ length: 100 }, (_, row) => ({
      hash: String(row), shortHash: String(row),
      parentHashes: row === 60 ? Array.from({ length: 8 }, (_, index) => String(61 + index))
        : row > 60 && row <= 68 ? ["69"] : row < 99 ? [String(row + 1)] : [],
      message: `subject ${row}`, author: "fixture", date: "unknown",
      decorations: row === 0 ? "HEAD -> main" : "",
    }));
    const layout = layoutGitGraph(commits);
    const render = (index: number) => renderToStaticMarkup(createElement(GitGraphRow, {
      row: layout.rows[index], showDecorations: true, recommendedLaneCount: layout.recommendedLaneCount,
    }));
    const svgWidth = (markup: string) => Number(markup.match(/<svg[^>]*width="(\d+)"/)![1]);
    const simple = render(0);
    const dense = render(64);
    const after = render(90);
    expect(svgWidth(simple)).toBeLessThan(117);
    expect(svgWidth(dense)).toBeGreaterThan(svgWidth(simple));
    expect(svgWidth(after)).toBe(svgWidth(simple));
    expect(simple).toContain("subject 0");
    expect(simple).toContain('data-reference-kind="branch"');
    expect(dense).toContain("subject 64");
  });
  test("compact long edges render solid arrow arms and filled nodes at 2x", () => {
    const commits: GitCommit[] = Array.from({ length: 40 }, (_, row) => ({
      hash: String(row),
      shortHash: String(row),
      parentHashes: row === 0 ? ["1", "39"] : row < 39 ? [String(row + 1)] : [],
      message: String(row),
      author: "fixture",
      date: "unknown",
      decorations: row === 0 ? "HEAD -> main" : "",
    }));
    const arrows = layoutGitGraph(commits).rows.filter((row) =>
      row.printElements.some((element) => element.hasArrow),
    );
    expect(arrows.length).toBeGreaterThan(0);
    for (const row of arrows) {
      const svg = renderToStaticMarkup(
        createElement(GitGraphRow, {
          row,
          showDecorations: false,
          paint: gitGraphPaintMetrics(26, 2),
        }),
      ).split("</svg>")[0];
      const paths = svg.match(/<path [^>]+>/g) ?? [];
      expect(
        paths.some(
          (path) => (path.match(/M /g) ?? []).length === 3 && !path.includes("stroke-dasharray"),
        ),
      ).toBe(true);
      expect(svg).toContain('stroke-width="1.5"');
      expect(svg).toContain('rx="4.25"');
      expect(svg).toContain('fill="currentColor"');
      expect(svg).not.toContain(" C ");
    }
  });

  test("unfiltered SVG connects shifted passing lanes at the same boundary midpoint", () => {
    const parents = [["1"], ["3", "2"], ["3", "5"], ["5", "4"], ["5"], []];
    const commits: GitCommit[] = parents.map((parentHashes, row) => ({
      hash: String(row),
      shortHash: String(row),
      parentHashes,
      message: String(row),
      author: "fixture",
      date: "unknown",
      decorations: row === 0 ? "HEAD -> main" : row === 1 ? "feature" : "",
    }));
    const layout = layoutGitGraph(commits);
    const current = renderToStaticMarkup(
      createElement(GitGraphRow, { row: layout.rows[3], showDecorations: false }),
    );
    const next = renderToStaticMarkup(
      createElement(GitGraphRow, { row: layout.rows[4], showDecorations: false }),
    );
    expect(current).toContain('d="M 26 13 L 34.5 26"');
    expect(next).toContain('d="M 43 13 L 34.5 0"');
    expect(current).not.toContain("<line ");
    expect(next).not.toContain("<line ");
  });

  test("unfiltered SVG paints two incoming colors separately at a merge endpoint", () => {
    const commits: GitCommit[] = [["main", "side"], ["root"], ["root"], []].map(
      (parentHashes, row) => ({
        hash: ["merge", "main", "side", "root"][row],
        shortHash: String(row),
        parentHashes,
        message: String(row),
        author: "fixture",
        date: "unknown",
        decorations: row === 0 ? "HEAD -> main" : row === 2 ? "feature" : "",
      }),
    );
    const layout = layoutGitGraph(commits);
    const svg = renderToStaticMarkup(
      createElement(GitGraphRow, { row: layout.rows[3], showDecorations: false }),
    ).split("</svg>")[0];
    expect(svg.match(/<path /g)).toHaveLength(2);
    for (const row of layout.rows.slice(1, 3))
      expect(svg).toContain(`--git-graph-light:${graphColor(row.parentEdges[0].colorIndex)}`);
  });

  test("renders both halves of a filtered ancestor edge as dashed SVG paths", () => {
    const commits: GitCommit[] = ["a", "b", "c"].map((hash, row) => ({
      hash,
      shortHash: hash,
      parentHashes: row < 2 ? [String.fromCharCode(hash.charCodeAt(0) + 1)] : [],
      message: hash,
      author: "fixture",
      date: "unknown",
      decorations: "",
    }));
    const layout = layoutGitGraph(commits, new Set(["a", "c"]));
    for (const row of layout.rows) {
      const svg = renderToStaticMarkup(
        createElement(GitGraphRow, { row, showDecorations: false }),
      ).split("</svg>")[0];
      expect(svg.match(/<path /g)).toHaveLength(1);
      expect(svg).toContain('stroke-dasharray="15 11"');
      expect(svg).not.toContain("<line ");
      expect(svg).toContain("<ellipse ");
    }
  });

  test("renders one compact reference group with full names and original kind markers", () => {
    const row = layoutGitGraph([{ hash: "tip", shortHash: "tip", parentHashes: [], message: "Subject", author: "Fixture", date: "unknown", decorations: "HEAD -> master, origin/master, tag: v1.0.0" }]).rows[0];
    const html = renderToStaticMarkup(createElement(GitGraphRow, { row, showDecorations: true }));
    expect(html.match(/data-git-reference-group=/g)).toHaveLength(1);
    expect(html).toContain("origin &amp; master");
    expect(html).toContain('aria-label="HEAD\nmaster\norigin/master\nv1.0.0"');
    for (const kind of ["head", "branch", "remote", "tag"]) expect(html).toContain(`data-reference-kind="${kind}"`);
  });
});
