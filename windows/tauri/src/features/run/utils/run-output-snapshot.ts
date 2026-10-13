// Pure naming helpers for run output snapshots. The buffer-open call itself
// lives in the run pane, which already links the editor buffer store; keeping
// this module store-free lets CI run its tests beside sibling files without
// pulling the store's dependency chain into the process.

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

/** `16-33-18` style stamp; colons are avoided so the value is path-safe. */
export function runOutputSnapshotStamp(at: Date): string {
  return `${pad2(at.getHours())}-${pad2(at.getMinutes())}-${pad2(at.getSeconds())}`;
}

/** Tab name shown in the editor area, e.g. `输出快照 16-33-18`. */
export function runOutputSnapshotName(label: string, at: Date): string {
  return `${label} ${runOutputSnapshotStamp(at)}`;
}

/**
 * Virtual buffer path. Each snapshot needs its own path so consecutive
 * snapshots open separate tabs instead of focusing a reused buffer.
 */
export function runOutputSnapshotPath(at: Date): string {
  const date = `${at.getFullYear()}-${pad2(at.getMonth() + 1)}-${pad2(at.getDate())}`;
  return `lithe-run://snapshot/${date}T${runOutputSnapshotStamp(at)}-${at.getMilliseconds()}`;
}
