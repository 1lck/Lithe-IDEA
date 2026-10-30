// Summaries of latency and frame samples. Every metric is "lower is better".

/** Nearest-rank percentile; NaN for an empty sample. */
export function percentile(values, p) {
  if (values.length === 0) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

export const median = (values) => percentile(values, 50);

/** Keydown-to-frame summary; a key is late when its frame came after the next refresh. */
export function keySummary(samples, refreshMilliseconds) {
  const lateThreshold = refreshMilliseconds + 2;
  const late = samples.filter((sample) => sample > lateThreshold).length;
  return {
    p50Ms: percentile(samples, 50),
    p95Ms: percentile(samples, 95),
    maxMs: samples.length ? Math.max(...samples) : Number.NaN,
    missedFramePct: samples.length ? (100 * late) / samples.length : Number.NaN,
  };
}

/** Frame pacing; a frame spanning k refresh intervals dropped k - 1 frames. */
export function frameSummary(frames, refreshMilliseconds) {
  let dropped = 0;
  let expected = 0;
  for (const frame of frames) {
    const intervals = Math.max(1, Math.round(frame / refreshMilliseconds));
    expected += intervals;
    dropped += intervals - 1;
  }
  return {
    frameP95Ms: percentile(frames, 95),
    frameMaxMs: frames.length ? Math.max(...frames) : Number.NaN,
    droppedFramesPct: expected ? (100 * dropped) / expected : 0,
  };
}

/** Total blocking time: the part of each long task beyond 50 ms. */
export function totalBlockingTime(tasks) {
  return tasks.reduce((sum, task) => sum + Math.max(0, task.duration - 50), 0);
}

/** Median of each metric across measured runs; a metric missing from a run is skipped. */
export function medianMetrics(runs) {
  const names = new Set(runs.flatMap((run) => Object.keys(run)));
  return Object.fromEntries(
    [...names].map((name) => [
      name,
      median(runs.map((run) => run[name]).filter((value) => Number.isFinite(value))),
    ]),
  );
}
