/** Owns starts before their first await so disabling cannot miss an in-flight launch. */
export class ExtensionProcessOwner {
  private readonly processes = new Map<
    string,
    { extensionId: string; workspaceId: string; ready: Promise<void>; stop: () => Promise<void>;
      options?: { cancel: () => void; stopOnFailedStart?: boolean } }
  >();

  async start(
    id: string,
    workspaceId: string,
    extensionId: string,
    launch: () => Promise<void>,
    stop: () => Promise<void>,
    options?: { cancel: () => void; stopOnFailedStart?: boolean },
  ) {
    // Schedule launch after registration, including synchronous launch failures.
    const ready = Promise.resolve().then(launch);
    const entry = { extensionId, workspaceId, ready, stop, options };
    this.processes.set(id, entry);
    try {
      await ready;
    } catch (error) {
      if (!options?.stopOnFailedStart && this.processes.get(id) === entry) this.processes.delete(id);
      throw error;
    }
  }

  finished(id: string) {
    this.processes.delete(id);
  }

  stopExecution(id: string): Promise<void> { return this.stop(undefined, undefined, id); }

  async stop(workspaceId?: string, extensionId?: string, executionId?: string) {
    const owned = [...this.processes].filter(
      ([id, entry]) =>
        (!workspaceId || entry.workspaceId === workspaceId) &&
        (!extensionId || entry.extensionId === extensionId) && (!executionId || executionId === id),
    );
    const outcomes = await Promise.allSettled(
      owned.map(async ([id, entry]) => {
        entry.options?.cancel();
        // A launch failure owns no process; successful late starts must still stop.
        const started = await entry.ready.then(
          () => true,
          () => false,
        );
        if (started || entry.options?.stopOnFailedStart) await entry.stop();
        if (this.processes.get(id) === entry) this.processes.delete(id);
      }),
    );
    const failed = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    if (failed) throw failed.reason;
  }
}
export const extensionProcessOwner = new ExtensionProcessOwner();
