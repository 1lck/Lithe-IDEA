import { expect, test } from "bun:test";
import {
  commitDiffConnectorPath,
  commitDiffPaintRange,
  commitDiffConnectorBorderPath,
} from "./commit-diff-chrome-geometry";

test("modified blocks keep both gutters straight and curve only across the divider", () => {
  expect(commitDiffConnectorPath(120, [10, 32], [20, 64], 44)).toBe(
    "M 0 10 L 44 10 C 60 10 60 20 76 20 L 120 20 L 120 64 L 76 64 C 60 64 60 32 44 32 L 0 32 Z",
  );
});
test("insertions and deletions retain a visible empty-side line at BOF and EOF", () => {
  expect(commitDiffPaintRange([0, 0])).toEqual([-1, 0]);
  expect(commitDiffConnectorPath(120, [0, 0], [0, 44], 44)).toBe(
    "M 0 -1 L 44 -1 C 60 -1 60 0 76 0 L 120 0 L 120 44 L 76 44 C 60 44 60 0 44 0 L 0 0 Z",
  );
  expect(commitDiffConnectorPath(120, [0, 44], [44, 44], 44)).toContain("L 120 43 L 120 44");
  expect(commitDiffConnectorPath(120, [-30, -8], [-20, 24], 44)).toContain(
    "C 60 -30 60 -20 76 -20",
  );
});
test("narrow divider geometry never produces gutters outside its width", () => {
  const path = commitDiffConnectorPath(20, [10, 32], [20, 64], 44);
  expect(path).toContain("L 10 10 C 10 10 10 20 10 20");
});

test("connector borders meet code boundaries after independent fractional scrolling without vertical seams", () => {
  const path = commitDiffConnectorBorderPath(88, [-3.25, 18.75], [40.5, 84.5], 36);
  expect(path).toBe(
    "M 0 -2.75 L 36 -2.75 C 44 -2.75 44 41 52 41 L 88 41 M 0 18.25 L 36 18.25 C 44 18.25 44 84 52 84 L 88 84",
  );
  const insertion = commitDiffConnectorBorderPath(88, [0, 0], [0, 44], 36);
  expect(insertion).toContain("M 0 -0.5");
  expect(insertion).toContain("M 0 0.5");
  expect(commitDiffConnectorBorderPath(88, [0, 44], [44, 44], 36)).toContain("L 88 44.5");
});
