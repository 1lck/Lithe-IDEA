import isEqual from "fast-deep-equal";
import { immer } from "zustand/middleware/immer";
import { createWithEqualityFn } from "zustand/traditional";
import { createSelectors } from "@/utils/zustand-selectors";

type JumpListEntrySource = "cursor" | "explicit";
type JumpListPosition = Omit<JumpListEntry, "timestamp">;

interface StoredJumpListEntry extends JumpListEntry {
  source: JumpListEntrySource;
}

interface JumpListHistory {
  entries: StoredJumpListEntry[];
  currentIndex: number;
}

export interface JumpListEntry {
  bufferId: string;
  filePath: string;
  paneId?: string;
  line: number;
  column: number;
  offset: number;
  scrollTop: number;
  scrollLeft: number;
  timestamp: number;
}

interface JumpListActions {
  pushEntry: (entry: JumpListPosition) => void;
  recordCursorEntry: (entry: JumpListPosition) => void;
  goBack: (currentPosition?: JumpListPosition, paneId?: string) => JumpListEntry | null;
  goForward: (paneId?: string) => JumpListEntry | null;
  canGoBack: (paneId?: string) => boolean;
  canGoForward: (paneId?: string) => boolean;
  clear: () => void;
}

interface JumpListState extends JumpListHistory {
  paneHistories: Record<string, JumpListHistory>;
  maxEntries: number;
  actions: JumpListActions;
}

const DEFAULT_MAX_ENTRIES = 100;
const DUPLICATE_LINE_THRESHOLD = 5;

function withTimestamp(entry: JumpListPosition, source: JumpListEntrySource): StoredJumpListEntry {
  return { ...entry, source, timestamp: Date.now() };
}

function getHistory(state: JumpListState, paneId?: string): JumpListHistory {
  if (!paneId) return state;

  const existingHistory = state.paneHistories[paneId];
  if (existingHistory) return existingHistory;

  const history = { entries: [], currentIndex: -1 };
  state.paneHistories[paneId] = history;
  return history;
}

function truncateForwardEntries(history: JumpListHistory) {
  if (history.currentIndex >= 0 && history.currentIndex < history.entries.length - 1) {
    history.entries = history.entries.slice(0, history.currentIndex + 1);
  }
}

function appendEntry(history: JumpListHistory, entry: StoredJumpListEntry, maxEntries: number) {
  history.entries.push(entry);
  if (history.entries.length > maxEntries) {
    history.entries.shift();
  }
}

export const useJumpListStore = createSelectors(
  createWithEqualityFn<JumpListState>()(
    immer((set, get) => ({
      entries: [],
      currentIndex: -1,
      paneHistories: {},
      maxEntries: DEFAULT_MAX_ENTRIES,

      actions: {
        pushEntry: (entry) => {
          set((state) => {
            const history = getHistory(state, entry.paneId);
            const newEntry = withTimestamp(entry, "explicit");

            // If we're in the middle of history, truncate future entries.
            truncateForwardEntries(history);

            // Check for duplicate (same file and within line threshold).
            const lastEntry = history.entries[history.entries.length - 1];
            if (lastEntry) {
              const isSameFile = lastEntry.filePath === newEntry.filePath;
              const isNearbyLine =
                Math.abs(lastEntry.line - newEntry.line) <= DUPLICATE_LINE_THRESHOLD;

              if (lastEntry.source !== "cursor" && isSameFile && isNearbyLine) {
                // Update the existing entry instead of adding a duplicate.
                history.entries[history.entries.length - 1] = newEntry;
                history.currentIndex = -1;
                return;
              }
            }

            appendEntry(history, newEntry, state.maxEntries);

            // Reset to present (not navigating history).
            history.currentIndex = -1;
          });
        },

        recordCursorEntry: (entry) => {
          set((state) => {
            const history = getHistory(state, entry.paneId);
            const newEntry = withTimestamp(entry, "cursor");

            // A new cursor movement after going back starts a new history branch.
            truncateForwardEntries(history);

            const lastEntry = history.entries[history.entries.length - 1];
            const isSamePosition =
              lastEntry &&
              lastEntry.bufferId === newEntry.bufferId &&
              lastEntry.filePath === newEntry.filePath &&
              lastEntry.line === newEntry.line &&
              lastEntry.column === newEntry.column &&
              lastEntry.offset === newEntry.offset;

            if (isSamePosition) {
              history.entries[history.entries.length - 1] = newEntry;
              history.currentIndex = -1;
              return;
            }

            appendEntry(history, newEntry, state.maxEntries);
            history.currentIndex = -1;
          });
        },

        goBack: (currentPosition, paneId) => {
          let result: JumpListEntry | null = null;
          const historyPaneId = paneId ?? currentPosition?.paneId;

          set((state) => {
            const history = getHistory(state, historyPaneId);
            if (history.entries.length === 0) return;

            let newIndex: number;
            if (history.currentIndex === -1) {
              // Currently at present - save current position so we can go forward to it.
              if (currentPosition) {
                appendEntry(
                  history,
                  withTimestamp(
                    historyPaneId ? { ...currentPosition, paneId: historyPaneId } : currentPosition,
                    "cursor",
                  ),
                  state.maxEntries,
                );
              }
              // Go to second-to-last entry (last entry is now where we just were).
              newIndex = history.entries.length - 2;
            } else if (history.currentIndex > 0) {
              // Go to previous entry.
              newIndex = history.currentIndex - 1;
            } else {
              // Already at the beginning.
              return;
            }

            if (newIndex < 0) return;

            const entry = history.entries[newIndex];
            if (!entry) return;

            history.currentIndex = newIndex;
            result = { ...entry };
          });

          return result;
        },

        goForward: (paneId) => {
          const state = get();
          const history = paneId ? state.paneHistories[paneId] : state;
          if (!history || history.currentIndex === -1 || history.currentIndex >= history.entries.length - 1) {
            return null;
          }

          const newIndex = history.currentIndex + 1;
          const entry = history.entries[newIndex];
          if (!entry) return null;

          set((state) => {
            getHistory(state, paneId).currentIndex = newIndex;
          });

          return entry;
        },

        canGoBack: (paneId) => {
          const state = get();
          const history = paneId ? state.paneHistories[paneId] : state;
          if (!history || history.entries.length === 0) return false;
          if (history.currentIndex === -1) return true;
          return history.currentIndex > 0;
        },

        canGoForward: (paneId) => {
          const state = get();
          const history = paneId ? state.paneHistories[paneId] : state;
          if (!history || history.currentIndex === -1) return false;
          return history.currentIndex < history.entries.length - 1;
        },

        clear: () => {
          set((state) => {
            state.entries = [];
            state.currentIndex = -1;
            state.paneHistories = {};
          });
        },
      },
    })),
    isEqual,
  ),
);
