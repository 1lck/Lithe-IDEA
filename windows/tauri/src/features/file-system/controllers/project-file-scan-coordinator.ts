export function createProjectFileScanCoordinator<Value>() {
  const pending = new Map<string, Promise<Value>>();

  return (key: string, scan: () => Promise<Value>): Promise<Value> => {
    const existingTask = pending.get(key);
    if (existingTask) return existingTask;

    const task = scan().finally(() => {
      if (pending.get(key) === task) pending.delete(key);
    });
    pending.set(key, task);
    return task;
  };
}
