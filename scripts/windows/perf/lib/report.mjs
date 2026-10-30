// Compares scenario medians with the budgets and an optional local baseline.

/**
 * Returns one row per budgeted or measured metric. `over` means the median is
 * above its budget; `regressed` means it is worse than the baseline by more than
 * the tolerance and by at least `regressionFloor`, so sub-millisecond noise on a
 * small value does not read as a regression.
 */
export function evaluate(results, budgets, baseline) {
  const { regressionTolerance, regressionFloor, metrics } = budgets;
  const rows = [];
  for (const [scenario, values] of Object.entries(results)) {
    for (const [metric, value] of Object.entries(values)) {
      const key = `${scenario}.${metric}`;
      const budget = metrics[key] ?? null;
      const previous = baseline?.[scenario]?.[metric] ?? null;
      const measurable = Number.isFinite(value);
      rows.push({
        key,
        value,
        budget,
        baseline: previous,
        over: budget !== null && (!measurable || value > budget),
        regressed:
          previous !== null &&
          measurable &&
          value > previous * (1 + regressionTolerance) &&
          value - previous >= regressionFloor,
      });
    }
  }
  // A budgeted metric with no measurement means a scenario stopped producing it.
  const measured = new Set(rows.map((row) => row.key));
  const scenarios = new Set(Object.keys(results));
  for (const [key, budget] of Object.entries(metrics)) {
    if (!measured.has(key) && scenarios.has(key.split(".")[0])) {
      rows.push({ key, value: Number.NaN, budget, baseline: null, over: true, regressed: false });
    }
  }
  return rows;
}

const format = (value) => {
  if (value === null || value === undefined) return "-";
  if (!Number.isFinite(value)) return "n/a";
  return Math.abs(value) >= 100 ? value.toFixed(0) : value.toFixed(1);
};

export function renderReport(rows) {
  const width = Math.max(...rows.map((row) => row.key.length), 6);
  const lines = [`${"metric".padEnd(width)}  ${"median".padStart(9)}  ${"budget".padStart(9)}  ${"baseline".padStart(9)}`];
  for (const row of rows) {
    const flags = [row.over ? "OVER" : "", row.regressed ? "REGRESSED" : ""].filter(Boolean).join(" ");
    lines.push(
      `${row.key.padEnd(width)}  ${format(row.value).padStart(9)}  ${format(row.budget).padStart(9)}  ${format(row.baseline).padStart(9)}  ${flags}`.trimEnd(),
    );
  }
  return lines.join("\n");
}
