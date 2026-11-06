/**
 * Thin adapter between pane groups and Core's `editor.workbenchState.reduce`.
 *
 * Membership and selection rules (de-duplication, which tab is selected after an open, close or
 * move, MRU order, pins, previews, and which groups become empty) live in
 * rust/lithe-core-rules and run here through the synchronous wasm bridge, because pane state is
 * updated inside zustand `set()` calls that cannot await. This file only converts a `PaneGroup`
 * to the canonical group and back; it never decides anything about membership itself.
 *
 * One call to {@link reduceWorkbenchGroups} is one Core round trip. Callers send every group an
 * action involves in that single call. Split directions, ratios and dragging stay in
 * `pane-tree.ts` and never reach Core.
 *
 * Note: .agents/notes/implemented/architecture/2026-11-05-core-rules-wasm-sync-bridge.md
 */
import isEqual from "fast-deep-equal";
import { executeCoreRuleSync } from "@/core/core-rules";
import type { PaneGroup } from "../types/pane.types";

export const WORKBENCH_STATE_REDUCE_COMMAND = "editor.workbenchState.reduce";

/** What Core does with a group that an action left empty. */
export type EmptyGroups = "keep" | "remove" | "removeKeepingFirst";

/** How Core picks the next selection when the selected tab leaves a group. */
export type SelectionFallback = "adjacent" | "first";

export type WorkbenchAction =
  | { kind: "normalize"; emptyGroups?: EmptyGroups; unplaced?: string[] }
  | { kind: "open"; group: string; member: string; activate?: boolean }
  | {
      kind: "close";
      group: string;
      member: string;
      emptyGroups?: EmptyGroups;
      selectionFallback?: SelectionFallback;
    }
  | { kind: "activate"; group: string; member: string | null }
  | {
      kind: "move";
      member: string;
      from: string;
      to: string;
      before?: string;
      after?: string;
      activate?: boolean;
      emptyGroups?: EmptyGroups;
      selectionFallback?: SelectionFallback;
    }
  | { kind: "reorder"; group: string; fromIndex: number; toIndex: number }
  | { kind: "setPinned"; group: string; member: string; pinned: boolean }
  | { kind: "setPinnedEverywhere"; member: string; pinned: boolean }
  | { kind: "setPreview"; group: string; member: string | null }
  | { kind: "clearPreviewEverywhere"; member: string }
  | { kind: "mergeGroup"; from: string; into: string; activateSelected?: boolean };

interface CoreGroup {
  id: string;
  members: string[];
  selected: string | null;
  mru: string[];
  pinned: string[];
  preview: string | null;
}

interface CoreReduction {
  state: { groups: CoreGroup[] };
  removedGroupIds: string[];
}

export interface WorkbenchReduction {
  /** Groups Core returned, in the order they were sent, minus the removed ones. */
  groups: PaneGroup[];
  /** Groups Core removed because an action emptied them; the caller prunes its layout tree. */
  removedGroupIds: string[];
}

function toCoreGroup(group: PaneGroup): CoreGroup {
  return {
    id: group.id,
    members: [...group.bufferIds],
    selected: group.activeBufferId,
    // A group that never recorded recency is ordered by its tabs.
    mru: [...(group.mruBufferIds ?? group.bufferIds)],
    pinned: [...(group.pinnedBufferIds ?? [])],
    preview: group.previewBufferId ?? null,
  };
}

function fromCoreGroup(previous: PaneGroup, core: CoreGroup): PaneGroup {
  const unchanged =
    isEqual(previous.bufferIds, core.members) &&
    previous.activeBufferId === core.selected &&
    isEqual(previous.mruBufferIds, core.mru) &&
    isEqual(previous.pinnedBufferIds, core.pinned) &&
    (previous.previewBufferId ?? null) === core.preview;
  if (unchanged) return previous;
  return {
    ...previous,
    bufferIds: core.members,
    activeBufferId: core.selected,
    mruBufferIds: core.mru,
    previewBufferId: core.preview,
    pinnedBufferIds: core.pinned,
  };
}

/**
 * Applies one action to `groups` with a single synchronous Core call. Groups keep their
 * non-membership fields (`locked`, ids) because only the canonical fields cross the boundary.
 */
export function reduceWorkbenchGroups(
  groups: PaneGroup[],
  action: WorkbenchAction,
): WorkbenchReduction {
  if (groups.length === 0) return { groups: [], removedGroupIds: [] };
  const result = executeCoreRuleSync<CoreReduction>(WORKBENCH_STATE_REDUCE_COMMAND, {
    state: { groups: groups.map(toCoreGroup) },
    action,
  });
  const previousById = new Map(groups.map((group) => [group.id, group]));
  return {
    groups: result.state.groups.map((core) => fromCoreGroup(previousById.get(core.id)!, core)),
    removedGroupIds: result.removedGroupIds,
  };
}
