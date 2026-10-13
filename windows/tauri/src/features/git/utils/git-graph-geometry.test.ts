import { expect, test } from "bun:test";
import { gitGraphPaintMetrics, gitGraphRowHeight } from "./git-graph-geometry";

test("uses the macOS 26px baseline with physical FLOOR/ODD metrics", () => {
  const one = gitGraphPaintMetrics(26, 1);
  expect([one.rowCenter, one.laneSpacing, one.laneCenter, one.lineWidth, one.nodeDiameter]).toEqual(
    [13, 17, 9, 1, 9],
  );
  const two = gitGraphPaintMetrics(26, 2);
  expect([two.rowCenter, two.laneSpacing, two.laneCenter, two.lineWidth, two.nodeDiameter]).toEqual(
    [12.5, 18.5, 9, 1.5, 8.5],
  );
  expect(one.titleOffset(0, [], 1)).toBe(22);
  expect(gitGraphRowHeight(13, 3)).toBe(26);
  expect(gitGraphRowHeight(24, 6, 1)).toBe(38);
});

test("title baseline follows the recommended graph width and caps only that baseline at six", () => {
  const paint = gitGraphPaintMetrics();
  expect(paint.titleOffset(0, [], 3)).toBe(60);
  expect(paint.titleOffset(0, [], 6)).toBe(117);
  expect(paint.titleOffset(0, [], 12)).toBe(117);
  expect(paint.titleOffset(8, [], 2)).toBe(174);
});

test("row title expands for a diagonal boundary midpoint without reserving its full adjacent lane", () => {
  const paint = gitGraphPaintMetrics();
  const edge = { position: 2, adjacentPosition: 8, direction: "down", isTerminal: false } as const;
  expect(paint.titleOffset(0, [edge], 2)).toBe(117);
  const next = { ...edge, position: 8, adjacentPosition: 2, direction: "up" } as const;
  expect(paint.titleOffset(8, [next], 2)).toBe(174);
  expect(paint.line(edge).end.x).toBe(paint.line(next).end.x);
});

for (const scale of [1, 1.25, 1.5, 2, 3]) {
  test(`shifted half-edges join at the same physical boundary at ${scale}x`, () => {
    const paint = gitGraphPaintMetrics(26, scale);
    const down = paint.line({
      position: 1,
      adjacentPosition: 2,
      direction: "down",
      isTerminal: false,
    });
    const up = paint.line({ position: 2, adjacentPosition: 1, direction: "up", isTerminal: false });
    expect(down.end.x).toBe(up.end.x);
    expect(down.end.y).toBe(26 + up.end.y);
    expect(Math.round(paint.lineWidth * scale) % 2).toBe(1);
    expect(Math.round(paint.nodeDiameter * scale) % 2).toBe(1);
    const node = paint.nodeRect(2);
    expect(node.x * scale).toBeCloseTo(Math.round(node.x * scale), 8);
    expect(node.y * scale).toBeCloseTo(Math.round(node.y * scale), 8);
  });
}

test("terminal markers retain the upstream gap and directional arrow arms", () => {
  const paint = gitGraphPaintMetrics();
  const down = { position: 0, adjacentPosition: 0, direction: "down", isTerminal: true } as const;
  expect(paint.line(down).end).toEqual({ x: 9, y: 23 });
  const arms = paint.arrowArms(down);
  expect(arms[0].y).toBeLessThan(23);
  expect(arms[1].y).toBeLessThan(23);
  expect(arms[0].x + arms[1].x).toBeCloseTo(18);
  const dash = paint.dash({ ...down, isTerminal: false });
  expect(dash).toEqual({ dash: 15, space: 11, phase: 7.5 });
});

for (const scale of [1, 1.25, 2]) {
  test(`arrow hit areas include the aligned tip and half-row at ${scale}x`, () => {
    const paint = gitGraphPaintMetrics(26, scale);
    for (const direction of ["up", "down"] as const) {
      const element = { position: 1, adjacentPosition: 2, direction, isTerminal: false };
      const { end } = paint.line(element);
      const rect = paint.arrowHitRect(element);
      expect(rect.width).toBe(12);
      expect(end.x).toBeGreaterThanOrEqual(rect.x);
      expect(end.x).toBeLessThanOrEqual(rect.x + rect.width);
      expect(end.y).toBeGreaterThanOrEqual(rect.y);
      expect(end.y).toBeLessThanOrEqual(rect.y + rect.height);
      expect(rect.y).toBeLessThanOrEqual(direction === "up" ? 0 : 13);
      expect(rect.y + rect.height).toBeGreaterThanOrEqual(direction === "up" ? 13 : 26);
    }
  });
}
