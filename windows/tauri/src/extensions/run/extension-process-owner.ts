import { pluginLifecycle } from "../registry/plugin-lifecycle";

type ResourceReservation = (pluginId: string, resourceId: string) => Promise<() => Promise<void>>;
interface OwnedProcess {
  extensionId: string;
  workspaceId: string;
  ready: Promise<void>;
  stop: () => Promise<void>;
  release?: () => Promise<void>;
  finished: boolean;
}

/** Owns starts before their first await so disabling cannot miss an in-flight launch. */
export class ExtensionProcessOwner {
  private readonly processes = new Map<string, OwnedProcess>();

  constructor(private readonly reserve: ResourceReservation = async () => async () => {}) {}

  async start(
    id: string,
    workspaceId: string,
    extensionId: string,
    launch: () => Promise<void>,
    stop: () => Promise<void>,
  ) {
    if (this.processes.has(id)) throw new Error(`Run ${id} is already owned`);
    const entry: OwnedProcess = { extensionId, workspaceId, stop, finished: false, ready: Promise.resolve() };
    this.processes.set(id, entry);
    entry.ready = Promise.resolve().then(async () => {
      entry.release = await this.reserve(extensionId, `run:${id}`);
      await launch();
    });
    try {
      await entry.ready;
      if (entry.finished) await this.release(id, entry);
    } catch (error) {
      await this.release(id, entry);
      throw error;
    }
  }

  private async release(id: string, entry: OwnedProcess) {
    await entry.release?.();
    if (this.processes.get(id) === entry) this.processes.delete(id);
  }

  async finished(id: string) {
    const entry = this.processes.get(id);
    if (!entry) return;
    entry.finished = true;
    // A terminal event can precede the native start response. Keep ownership
    // until that response settles, so disable also observes this launch.
    await entry.ready.catch(() => undefined);
    await this.release(id, entry);
  }

  async stop(workspaceId?: string, extensionId?: string) {
    const owned = [...this.processes].filter(
      ([, entry]) =>
        (!workspaceId || entry.workspaceId === workspaceId) &&
        (!extensionId || entry.extensionId === extensionId),
    );
    const results = await Promise.allSettled(owned.map(async ([id, entry]) => {
      const started = await entry.ready.then(() => true, () => false);
      if (started && !entry.finished) await entry.stop();
      await this.release(id, entry);
    }));
    const errors = results.filter((result) => result.status === "rejected");
    if (errors.length) throw new Error(`Could not stop plugin runs: ${errors.map((result) => String(result.reason)).join("; ")}`);
  }
}
export const extensionProcessOwner = new ExtensionProcessOwner((plugin, resource) => pluginLifecycle.reserve(plugin, resource));
