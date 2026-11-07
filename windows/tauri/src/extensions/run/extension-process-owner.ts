/** Owns starts before their first await so disabling cannot miss an in-flight launch. */
export class ExtensionProcessOwner {
  private readonly processes = new Map<
    string,
    {
      extensionId: string;
      workspaceId: string;
      ready: Promise<void>;
      stop: () => Promise<void>;
      cancel?: () => void;
      retainOnLaunchFailure?: () => boolean;
    }
  >();

  async start(
    id: string,
    workspaceId: string,
    extensionId: string,
    launch: () => Promise<void>,
    stop: () => Promise<void>,
    cancel?: () => void,
    retainOnLaunchFailure?: () => boolean,
  ) {
    // Schedule launch after registration, including synchronous launch failures.
    const ready = Promise.resolve().then(launch);
    this.processes.set(id, {
      extensionId,
      workspaceId,
      ready,
      stop,
      cancel,
      retainOnLaunchFailure,
    });
    try {
      await ready;
    } catch (error) {
      // A rejected native start may already have published a process whose
      // cleanup failed. Keep its owner until a later stop confirms termination.
      if (!retainOnLaunchFailure?.()) this.processes.delete(id);
      throw error;
    }
  }

  finished(id: string) {
    this.processes.delete(id);
  }

  async stop(workspaceId?: string, extensionId?: string) {
    const owned = [...this.processes].filter(
      ([, entry]) =>
        (!workspaceId || entry.workspaceId === workspaceId) &&
        (!extensionId || entry.extensionId === extensionId),
    );
    await Promise.all(
      owned.map(async ([id, entry]) => {
        entry.cancel?.();
        // Ordinary launch failures own nothing. A caller that could not confirm
        // cleanup must still drain its native process on this or a later retry.
        const started = await entry.ready.then(
          () => true,
          () => entry.retainOnLaunchFailure?.() ?? false,
        );
        if (started) await entry.stop();
        this.processes.delete(id);
      }),
    );
  }
}
export const extensionProcessOwner = new ExtensionProcessOwner();
