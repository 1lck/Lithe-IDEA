import assert from "node:assert/strict";
import { test } from "node:test";
import { frameSummary, keySummary, medianMetrics, percentile, totalBlockingTime } from "./stats.mjs";
import { evaluate, renderReport } from "./report.mjs";

test("percentile uses nearest rank and reports empty samples as NaN", () => {
  assert.equal(percentile([1, 2, 3, 4], 50), 2);
  assert.equal(percentile([1, 2, 3, 4], 95), 4);
  assert.ok(Number.isNaN(percentile([], 50)));
});

test("a key is late only when its frame misses the next refresh", () => {
  const summary = keySummary([10, 16, 18.7, 19, 40], 16.7);
  assert.equal(summary.missedFramePct, 40);
  assert.equal(summary.maxMs, 40);
});

test("a long frame counts every refresh interval it spanned as dropped", () => {
  const summary = frameSummary([16.7, 16.7, 50.1], 16.7);
  assert.equal(summary.droppedFramesPct, 40);
});

test("blocking time counts only the part of a task beyond 50 ms", () => {
  assert.equal(totalBlockingTime([{ duration: 40 }, { duration: 120 }]), 70);
});

test("metric medians skip runs that did not produce the metric", () => {
  assert.deepEqual(medianMetrics([{ a: 1, b: 9 }, { a: 3 }, { a: 2, b: Number.NaN }]), { a: 2, b: 9 });
});

const budgets = { regressionTolerance: 0.2, regressionFloor: 1, metrics: { "typing.p95Ms": 20, "typing.maxMs": 33 } };

test("a median above budget is over and a missing budgeted metric fails", () => {
  const rows = evaluate({ typing: { p95Ms: 25 } }, budgets, null);
  assert.deepEqual(
    rows.map((row) => [row.key, row.over]),
    [["typing.p95Ms", true], ["typing.maxMs", true]],
  );
});

test("regressions need both the relative tolerance and the absolute floor", () => {
  const baseline = { typing: { p95Ms: 10, p50Ms: 1 } };
  const rows = evaluate({ typing: { p95Ms: 13, p50Ms: 1.5, maxMs: 30 } }, budgets, baseline);
  assert.equal(rows.find((row) => row.key === "typing.p95Ms").regressed, true);
  assert.equal(rows.find((row) => row.key === "typing.p50Ms").regressed, false);
});

test("the report flags over-budget and regressed rows", () => {
  const text = renderReport(evaluate({ typing: { p95Ms: 25, maxMs: 30 } }, budgets, { typing: { p95Ms: 10 } }));
  assert.match(text, /typing\.p95Ms\s+25\.0\s+20\.0\s+10\.0\s+OVER REGRESSED/);
});
