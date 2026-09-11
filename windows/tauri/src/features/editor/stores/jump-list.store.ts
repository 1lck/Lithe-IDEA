import isEqual from "fast-deep-equal";
import { immer } from "zustand/middleware/immer";
import { createWithEqualityFn } from "zustand/traditional";
import { createSelectors } from "@/utils/zustand-selectors";

type JumpListEntrySource = "cursor" | "explicit";
type JumpListPosition = Omit<JumpListEntry, "timestamp">;

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

interface StoredJumpListEntry extends JumpListEntry {
  source: JumpListEntrySource;
}

interface JumpListActions {
  pushEntry: (entry: JumpListPosition) => void;
  recordCursorEntry: (entry: JumpListPosition) => void;
  goBack: (currentPosition?: JumpListPosition) => JumpListEntry | null;
  goForward: () => JumpListEntry | null;
  rollbackNavigation: (entry: JumpListEntry, previousIndex: number, removePresent: boolean) => void;
  canGoBack: () => boolean;
  canGoForward: () => boolean;
  clear: () => void;
}

interface JumpListState {
  entries: StoredJumpListEntry[];
  currentIndex: number;
  maxEntries: number;
  actions: JumpListActions;
}

const DEFAULT_MAX_ENTRIES = 100;

function withTimestamp(entry: JumpListPosition, source: JumpListEntrySource): StoredJumpListEntry {
  return { ...entry, source, timestamp: Date.now() };
}

function truncateForwardEntries(state: JumpListState) {
  if (state.currentIndex >= 0 && state.currentIndex < state.entries.length - 1) {
    state.entries = state.entries.slice(0, state.currentIndex + 1);
  }
}

function appendEntry(state: JumpListState, entry: StoredJumpListEntry) {
  state.entries.push(entry);
  if (state.entries.length > state.maxEntries) {
    state.entries.shift();
  }
}

export const useJumpListStore = createSelectors(
  createWithEqualityFn<JumpListState>()(
    immer((set, get) => ({
      entries: [],
      currentIndex: -1,
      maxEntries: DEFAULT_MAX_ENTRIES,

      actions: {
        pushEntry: (entry) => {
          set((state) => {
            const newEntry = withTimestamp(entry, "explicit");

            // If we're in the middle of history, truncate future entries.
            truncateForwardEntries(state);

            const lastEntry = state.entries[state.entries.length - 1];
            const isSamePosition =
              lastEntry &&
              lastEntry.source !== "cursor" &&
              lastEntry.filePath === newEntry.filePath &&
              lastEntry.paneId === newEntry.paneId &&
              lastEntry.line === newEntry.line &&
              lastEntry.column === newEntry.column &&
              lastEntry.offset === newEntry.offset;

            if (isSamePosition) {
              // Update the existing entry instead of adding a duplicate.
              state.entries[state.entries.length - 1] = newEntry;
              state.currentIndex = -1;
              return;
            }

            appendEntry(state, newEntry);

            // Reset to present (not navigating history).
            state.currentIndex = -1;
          });
        },

        recordCursorEntry: (entry) => {
          set((state) => {
            const newEntry = withTimestamp(entry, "cursor");

            // A new cursor movement after going back starts a new history branch.
            truncateForwardEntries(state);

            const lastEntry = state.entries[state.entries.length - 1];
            const isSamePosition =
              lastEntry &&
              lastEntry.bufferId === newEntry.bufferId &&
              lastEntry.filePath === newEntry.filePath &&
              lastEntry.paneId === newEntry.paneId &&
              lastEntry.line === newEntry.line &&
              lastEntry.column === newEntry.column &&
              lastEntry.offset === newEntry.offset;

            if (isSamePosition) {
              state.entries[state.entries.length - 1] = newEntry;
              state.currentIndex = -1;
              return;
            }

            appendEntry(state, newEntry);
            state.currentIndex = -1;
          });
        },

        goBack: (currentPosition) => {
          let result: JumpListEntry | null = null;

          set((state) => {
            if (state.entries.length === 0) return;

            let newIndex: number;
            if (state.currentIndex === -1) {
              // Currently at present - save current position so we can go forward to it.
              if (currentPosition) {
                appendEntry(state, withTimestamp(currentPosition, "cursor"));
              }
              // Go to second-to-last entry (last entry is now where we just were).
              newIndex = state.entries.length - 2;
            } else if (state.currentIndex > 0) {
              // Go to previous entry.
              newIndex = state.currentIndex - 1;
            } else {
              // Already at the beginning.
              return;
            }

            if (newIndex < 0) return;

            const entry = state.entries[newIndex];
            if (!entry) return;

            state.currentIndex = newIndex;
            result = { ...entry };
          });

          return result;
        },

        goForward: () => {
          const state = get();
          if (state.currentIndex === -1 || state.currentIndex >= state.entries.length - 1) {
            return null;
          }

          const newIndex = state.currentIndex + 1;
          const entry = state.entries[newIndex];
          if (!entry) return null;

          set((state) => {
            state.currentIndex = newIndex;
          });

          return { ...entry };
        },

        rollbackNavigation: (entry, previousIndex, removePresent) => {
          set((state) => {
            const current = state.entries[state.currentIndex];
            if (!current || current.timestamp !== entry.timestamp) return;
            if (removePresent) state.entries.pop();
            state.currentIndex = previousIndex;
          });
        },

        canGoBack: () => {
          const state = get();
          if (state.entries.length === 0) return false;
          if (state.currentIndex === -1) return true;
          return state.currentIndex > 0;
        },

        canGoForward: () => {
          const state = get();
          if (state.currentIndex === -1) return false;
          return state.currentIndex < state.entries.length - 1;
        },

        clear: () => {
          set((state) => {
            state.entries = [];
            state.currentIndex = -1;
          });
        },
      },
    })),
    isEqual,
  ),
);
