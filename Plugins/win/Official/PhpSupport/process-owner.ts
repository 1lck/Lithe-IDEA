/** Owns starts before their first await so disabling cannot miss an in-flight launch. */
export class PhpProcessOwner {
  private readonly processes = new Map<
    string,
    { workspaceId: string; ready: Promise<void>; stop: () => Promise<void> }
  >();

  async start(
    id: string,
    workspaceId: string,
    launch: () => Promise<void>,
    stop: () => Promise<void>,
  ) {
    // Schedule launch after registration, including synchronous launch failures.
    const ready = Promise.resolve().then(launch);
    this.processes.set(id, { workspaceId, ready, stop });
    try {
      await ready;
    } catch (error) {
      this.processes.delete(id);
      throw error;
    }
  }

  finished(id: string) {
    this.processes.delete(id);
  }

  async stop(workspaceId?: string) {
    const owned = [...this.processes].filter(
      ([, entry]) => !workspaceId || entry.workspaceId === workspaceId,
    );
    await Promise.all(
      owned.map(async ([id, entry]) => {
        // A launch failure owns no process; successful late starts must still stop.
        const started = await entry.ready.then(
          () => true,
          () => false,
        );
        if (started) await entry.stop();
        this.processes.delete(id);
      }),
    );
  }
}
export const phpProcessOwner = new PhpProcessOwner();
