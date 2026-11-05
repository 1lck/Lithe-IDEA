import { invoke } from "@/platform/tauri-core";

/** What a run replaces in the stored history: exact result ids and id prefixes. */
export interface TestOutcomeMergeScope {
  ids?: readonly string[];
  prefixes?: readonly string[];
}

export interface MergedTestOutcome {
  source: "previous" | "incoming";
  /** Position in the `previous` or `incoming` list sent to Core. */
  index: number;
}

/**
 * Merges a run's results into the stored history inside the scope the
 * provider adapter states (`build.mergeTestOutcomes`). Core compares ids
 * only; the caller keeps the payloads and maps the entries back.
 */
export function mergeTestOutcomes(request: {
  previous: readonly string[];
  incoming: readonly string[];
  scope: TestOutcomeMergeScope;
}): Promise<{ entries: MergedTestOutcome[] }> {
  return invoke<{ entries: MergedTestOutcome[] }>("build.mergeTestOutcomes", request);
}
