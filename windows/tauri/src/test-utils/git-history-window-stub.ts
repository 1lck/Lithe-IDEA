import * as native from "@/platform/tauri-core";
import { spyOn } from "bun:test";

const MAX_WINDOW_COMMITS = 5_000;

/**
 * Stand-in for Core's `git.historyWindow` in Git Log tests. The rules belong to
 * Core (`git/history_window.rs`); `git-history-window-stub.test.ts` replays the
 * shared fixture `history-window-v1.json` through this stub so it cannot drift.
 */
export function stubGitHistoryWindow(request: Record<string, any>): unknown {
  switch (request.operation) {
    case "refreshPlan": {
      const limit = request.preserveLoaded
        ? Math.max(request.pageSize, request.loadedCount)
        : request.pageSize;
      return { limit: Math.min(limit, MAX_WINDOW_COMMITS) };
    }
    case "extendPlan": {
      const { previous, page, canContinue } = request as Record<string, string[] & boolean>;
      const tail = previous[previous.length - 1];
      if (tail === undefined || !canContinue || page.includes(tail)) return { extensionLimit: 0 };
      const offset = page.findIndex((hash: string) => previous.includes(hash));
      if (offset < 0) return { extensionLimit: 0 };
      const previousIndex = previous.indexOf(page[offset]!);
      return {
        extensionLimit: Math.max(
          0,
          Math.min(offset - previousIndex, MAX_WINDOW_COMMITS - page.length),
        ),
      };
    }
    case "mergePage": {
      const loaded = new Set<string>(request.window);
      const append: number[] = [];
      request.page.forEach((hash: string, index: number) => {
        if (!loaded.has(hash) && loaded.size < MAX_WINDOW_COMMITS) {
          loaded.add(hash);
          append.push(index);
        }
      });
      return {
        append,
        hasMore:
          request.pageHasMore &&
          append.length > 0 &&
          request.window.length + append.length < MAX_WINDOW_COMMITS,
      };
    }
    default: {
      const window: string[] = request.window;
      const isLoaded = (hash: string | null) => !!hash && window.includes(hash);
      const focused = isLoaded(request.focused) ? request.focused : (window[0] ?? null);
      let selected = window.filter((hash) => request.selected.includes(hash));
      if (selected.length === 0 && focused) selected = [focused];
      return { selected, focused, anchor: isLoaded(request.anchor) ? request.anchor : focused };
    }
  }
}

/** Routes `git.historyWindow` to the stub; other Core commands keep their behavior. */
export function installGitHistoryWindowStub() {
  const original = native.invoke;
  return spyOn(native, "invoke").mockImplementation((async (command: string, payload?: unknown) =>
    command === "git.historyWindow"
      ? stubGitHistoryWindow(payload as Record<string, unknown>)
      : original(command, payload as Record<string, unknown>)) as typeof native.invoke);
}
