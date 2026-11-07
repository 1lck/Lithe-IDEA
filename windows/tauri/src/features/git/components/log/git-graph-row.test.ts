import { describe, expect, test } from "bun:test";
import { GitGraphCanvas, GitGraphRow, gitGraphWidth } from "./git-graph-row";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { graphFixtureLayout } from "@/test-utils/git-graph-projection-stub";
import { graphColor } from "../../utils/git-graph-colors";
import { gitGraphPaintMetrics } from "../../utils/git-graph-geometry";

describe("git graph decoration labels", () => {
  test("subject and references use each row's graph extent within a shared recommended baseline", () => {
    const layout = graphFixtureLayout("wideMerge");
    const render = (index: number) => renderToStaticMarkup(createElement(GitGraphRow, {
      row: layout.rows[index], showDecorations: true, recommendedLaneCount: layout.recommendedLaneCount,
    }));
    const spacerWidth = (markup: string) => Number(markup.match(/git-graph-row-spacer[^>]*style="width:(\d+)px/)![1]);
    const simple = render(0);
    const dense = render(34);
    const after = render(55);
    expect(spacerWidth(simple)).toBeLessThan(117);
    expect(spacerWidth(dense)).toBeGreaterThan(spacerWidth(simple));
    expect(spacerWidth(after)).toBe(spacerWidth(simple));
    expect(simple).toContain(">0<");
    expect(simple).toContain('data-reference-kind="branch"');
    expect(dense).toContain(">34<");
  });
  test("compact long edges render solid arrow arms and filled nodes at 2x", () => {
    const arrows = graphFixtureLayout("compactLongEdge").rows.filter((row) =>
      row.printElements.some((element) => element.hasArrow),
    );
    expect(arrows.length).toBeGreaterThan(0);
    for (const row of arrows) {
      const paint = gitGraphPaintMetrics(26, 2);
      const svg = renderToStaticMarkup(
        createElement(GitGraphCanvas, {
          rows: [row],
          paint,
          graphWidth: gitGraphWidth([row], paint),
        }),
      );
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
    const layout = graphFixtureLayout("shiftedForks");
    const paint = gitGraphPaintMetrics();
    const canvas = renderToStaticMarkup(
      createElement(GitGraphCanvas, {
        rows: layout.rows.slice(3, 5),
        paint,
        graphWidth: gitGraphWidth(layout.rows.slice(3, 5), paint),
      }),
    );
    expect(canvas).toContain('M 26 13 L 34.5 26 L 43 39');
    expect(canvas).toContain('M 43 39 L 26 52');
    expect(canvas).toContain('transform="translate(0 0)"');
    expect(canvas).toContain('transform="translate(0 26)"');
    expect(canvas).not.toContain("<line ");
  });

  test("unfiltered SVG paints two incoming colors separately at a merge endpoint", () => {
    const layout = graphFixtureLayout("namedMergeEndpoint");
    const paint = gitGraphPaintMetrics();
    const svg = renderToStaticMarkup(
      createElement(GitGraphCanvas, {
        rows: [layout.rows[3]],
        paint,
        graphWidth: gitGraphWidth([layout.rows[3]], paint),
      }),
    );
    expect(svg.match(/<path /g)).toHaveLength(2);
    for (const row of layout.rows.slice(1, 3))
      expect(svg).toContain(`--git-graph-light:${graphColor(row.parentEdges[0].colorId)}`);
  });

  test("keeps same-row fork edges separate when edge ids contain colons", () => {
    const layout = graphFixtureLayout("forkAndMerge");
    const paint = gitGraphPaintMetrics();
    const svg = renderToStaticMarkup(
      createElement(GitGraphCanvas, {
        rows: layout.rows,
        paint,
        graphWidth: gitGraphWidth(layout.rows, paint),
      }),
    );
    expect(svg).toContain('d="M 9 13 L 9 26 L 9 39"');
    expect(svg).toContain('d="M 9 13 L 17.5 26 L 26 39"');
  });

  test("renders both halves of a filtered ancestor edge as dashed SVG paths", () => {
    const layout = graphFixtureLayout("filteredDottedAncestor");
    for (const row of layout.rows) {
      const paint = gitGraphPaintMetrics();
      const svg = renderToStaticMarkup(
        createElement(GitGraphCanvas, {
          rows: [row],
          paint,
          graphWidth: gitGraphWidth([row], paint),
        }),
      );
      expect(svg.match(/<path /g)).toHaveLength(1);
      expect(svg).toContain('stroke-dasharray="15 11"');
      expect(svg).not.toContain("<line ");
      expect(svg).toContain("<ellipse ");
    }
  });

  test("renders one compact reference group with full names and original kind markers", () => {
    const row = graphFixtureLayout("decoratedTip").rows[0];
    const html = renderToStaticMarkup(createElement(GitGraphRow, { row, showDecorations: true }));
    expect(html.match(/data-git-reference-group=/g)).toHaveLength(1);
    expect(html).toContain("origin &amp; master");
    expect(html).toContain('aria-label="HEAD\nmaster\norigin/master\nv1.0.0"');
    for (const kind of ["head", "branch", "remote", "tag"]) expect(html).toContain(`data-reference-kind="${kind}"`);
  });

  test("renders the checked-out HEAD node as IDEA's larger ring with a filled center", () => {
    const layout = graphFixtureLayout("headAndRoot");
    const paint = gitGraphPaintMetrics();
    const svg = renderToStaticMarkup(
      createElement(GitGraphCanvas, {
        rows: layout.rows,
        rowOffset: 29,
        paint,
        graphWidth: gitGraphWidth(layout.rows, paint),
      }),
    );
    expect(svg).toContain('style="top:754px"');
    expect(svg).toContain('height="52"');
    const ellipses = svg.match(/<ellipse [^>]+>/g) ?? [];
    expect(ellipses[0]).toContain('fill="none"');
    expect(ellipses[0]).toContain('stroke="currentColor"');
    expect(ellipses[0]).toContain('rx="5.5"');
    expect(ellipses[0]).toContain('stroke-width="2"');
    expect(ellipses[1]).toContain('fill="currentColor"');
    expect(ellipses[1]).toContain('rx="2.5"');
    for (const ellipse of ellipses.slice(0, 2)) {
      expect(ellipse).toContain('cx="9"');
      expect(ellipse).toContain('cy="13"');
    }
    expect(ellipses[2]).toContain('fill="currentColor"');
    expect(ellipses[2]).toContain('rx="4.5"');
    expect(svg).toMatch(/data-git-graph-edges="true" clip-path="url\(#[^)]+\)"/);
    expect(svg).toContain('clip-rule="evenodd"');
    expect(svg).toContain('M 2.5 13 a 6.5 6.5 0 1 0 13 0 a 6.5 6.5 0 1 0 -13 0 Z');
  });
});
