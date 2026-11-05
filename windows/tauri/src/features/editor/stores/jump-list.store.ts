import isEqual from "fast-deep-equal";
import { createWithEqualityFn } from "zustand/traditional";
import { invoke } from "@/platform/tauri-core";
import { createSelectors } from "@/utils/zustand-selectors";
import { logger } from "../utils/logger";

/** One editor position the user can return to. */
export interface JumpListEntry {
  bufferId: string;
  filePath: string;
  paneId?: string;
  line: number;
  column: number;
  offset: number;
  scrollTop: number;
  scrollLeft: number;
}

/**
 * Core wire form. Core compares `document`, `line` and `column`; the Windows
 * pane, buffer, offset and scroll values travel unchanged in `context`.
 */
interface HistoryLocation {
  document: string;
  line: number;
  column: number;
  context: Omit<JumpListEntry, "filePath" | "line" | "column">;
}

export interface NavigationHistoryState {
  back: HistoryLocation[];
  forward: HistoryLocation[];
}

type HistoryEvent =
  | { type: "record"; departure: HistoryLocation; destination: HistoryLocation | null }
  | { type: "back" | "forward"; current: HistoryLocation | null };

interface ReduceResponse {
  state: NavigationHistoryState;
  destination: HistoryLocation | null;
}

/** A step the caller must roll back when its destination cannot be opened. */
export interface JumpListStep {
  entry: JumpListEntry;
  previous: NavigationHistoryState;
  next: NavigationHistoryState;
}

interface JumpListActions {
  /** Records a jump away from `departure`; `destination` is null when unresolved. */
  record: (departure: JumpListEntry, destination?: JumpListEntry | null) => Promise<void>;
  goBack: (current?: JumpListEntry) => Promise<JumpListStep | null>;
  goForward: (current?: JumpListEntry) => Promise<JumpListStep | null>;
  rollback: (step: JumpListStep) => void;
  canGoBack: () => boolean;
  canGoForward: () => boolean;
  clear: () => void;
}

interface JumpListState {
  history: NavigationHistoryState;
  actions: JumpListActions;
}

const EMPTY_HISTORY: NavigationHistoryState = { back: [], forward: [] };

function toLocation(entry: JumpListEntry): HistoryLocation {
  const { filePath, line, column, ...context } = entry;
  return { document: filePath, line, column, context };
}

function toEntry(location: HistoryLocation): JumpListEntry {
  return {
    ...location.context,
    filePath: location.document,
    line: location.line,
    column: location.column,
  };
}

// Core owns the stack rules. Reductions run one at a time so every event
// applies to the state produced by the previous one.
let reductionQueue: Promise<unknown> = Promise.resolve();

export const useJumpListStore = createSelectors(
  createWithEqualityFn<JumpListState>()(
    (set, get) => {
      const reduce = (event: HistoryEvent): Promise<JumpListStep | null> => {
        const reduction = reductionQueue.then(async () => {
          const previous = get().history;
          let response: ReduceResponse;
          try {
            response = await invoke<ReduceResponse>("editor.navigationHistory.reduce", {
              state: previous,
              event,
            });
          } catch (error) {
            logger.error("JumpList", "Navigation history update failed:", error);
            return null;
          }
          // clear() may have run while the request was in flight.
          if (get().history !== previous) return null;
          set({ history: response.state });
          return response.destination
            ? { entry: toEntry(response.destination), previous, next: response.state }
            : null;
        });
        reductionQueue = reduction.catch(() => undefined);
        return reduction;
      };

      return {
        history: EMPTY_HISTORY,
        actions: {
          record: async (departure, destination = null) => {
            await reduce({
              type: "record",
              departure: toLocation(departure),
              destination: destination ? toLocation(destination) : null,
            });
          },
          goBack: (current) =>
            reduce({ type: "back", current: current ? toLocation(current) : null }),
          goForward: (current) =>
            reduce({ type: "forward", current: current ? toLocation(current) : null }),
          rollback: (step) => {
            // A later jump owns the history now; do not overwrite it.
            if (get().history === step.next) set({ history: step.previous });
          },
          canGoBack: () => get().history.back.length > 0,
          canGoForward: () => get().history.forward.length > 0,
          clear: () => set({ history: EMPTY_HISTORY }),
        },
      };
    },
    isEqual,
  ),
);
