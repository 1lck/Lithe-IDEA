/** Serialize index writes per resolved repository without blocking other repositories. */
export function createRepositoryWriteQueue() {
  const tails = new Map<string, Promise<unknown>>();

  return function enqueue<T>(repositoryPath: string, write: () => Promise<T>): Promise<T> {
    const previous = tails.get(repositoryPath) ?? Promise.resolve();
    const request = previous.catch(() => undefined).then(write);
    tails.set(repositoryPath, request);
    const cleanup = () => {
      if (tails.get(repositoryPath) === request) tails.delete(repositoryPath);
    };
    // Handle both outcomes without hiding the rejection from the caller.
    void request.then(cleanup, cleanup);
    return request;
  };
}

/** Coalesce refreshes, including one trailing read when a write arrives during a read. */
export function createGitRefreshQueue() {
  const requests = new Map<string, { dirty: boolean; promise: Promise<void> }>();
  return {
    clear: () => requests.clear(),
    run(key: string, refresh: () => Promise<void>): Promise<void> {
      const existing = requests.get(key);
      if (existing) {
        existing.dirty = true;
        return existing.promise;
      }
      const entry = { dirty: true, promise: Promise.resolve() };
      entry.promise = Promise.resolve().then(async () => {
        try {
          while (entry.dirty) {
            entry.dirty = false;
            await refresh();
          }
        } finally {
          if (requests.get(key) === entry) requests.delete(key);
        }
      });
      requests.set(key, entry);
      return entry.promise;
    },
  };
}
