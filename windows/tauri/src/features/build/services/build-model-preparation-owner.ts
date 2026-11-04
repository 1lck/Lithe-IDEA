import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { BuildInstance, BuildRequiredOptions, WindowsBuildProviderWorkspace } from "./build-provider-workspace";

interface PendingModel {
  operationID: string; inputs: string; settled: boolean; waiters: Set<symbol>; completion: Promise<unknown>;
}
type ModelPorts = Pick<WindowsBuildProviderWorkspace, "hasCurrentModel" | "loadModel" | "cancel">
  & Partial<Pick<WindowsBuildProviderWorkspace, "subscribe" | "operationOutput">>;

/** Operations within one model scope share its preparation. Each waiter
 * owns its cancellation; the last departing waiter stops unused work. */
export class BuildModelPreparationOwner {
  private readonly pending = new Map<string, PendingModel>();
  private disposed = false;
  constructor(private readonly domain: ModelPorts, private readonly requiredOptions?: BuildRequiredOptions) {}

  async ensure(instance: BuildInstance, signal: AbortSignal, onOutput?: (text: string) => void): Promise<void> {
    signal.throwIfAborted();
    if (this.disposed) throw new DOMException("Aborted", "AbortError");
    if (this.domain.hasCurrentModel(instance)) return;
    const key = JSON.stringify([instance.pluginID, instance.buildSystemID, instance.root]);
    const inputs = JSON.stringify(Object.entries(instance.options).sort(([left], [right]) => left.localeCompare(right)));
    let entry = this.pending.get(key);
    if (entry && entry.inputs !== inputs) { this.domain.cancel(entry.operationID); this.pending.delete(key); entry = undefined; }
    if (!entry) {
      const started = this.domain.loadModel(structuredClone(instance), this.requiredOptions);
      entry = { ...started, inputs, settled: false, waiters: new Set() };
      this.pending.set(key, entry);
      const captured = entry;
      const finished = () => { captured.settled = true; if (this.pending.get(key) === captured) this.pending.delete(key); };
      void entry.completion.then(finished, finished);
    }
    const waiter = Symbol(); entry.waiters.add(waiter);
    const operationID = entry.operationID;
    let offset = 0;
    const drain = () => {
      if (!onOutput || signal.aborted) return;
      const value = this.domain.operationOutput?.(operationID);
      if (!value || value.offset <= offset) return;
      onOutput(value.output.slice(Math.max(0, offset - (value.offset - value.output.length)))); offset = value.offset;
    };
    const unsubscribe = onOutput ? this.domain.subscribe?.(drain) : undefined;
    try { drain(); await awaitBuildPreparation(entry.completion, signal); drain(); }
    finally {
      unsubscribe?.();
      entry.waiters.delete(waiter);
      if (!entry.settled && !entry.waiters.size) this.domain.cancel(entry.operationID);
    }
  }
  dispose(): void {
    this.disposed = true;
    for (const entry of this.pending.values()) this.domain.cancel(entry.operationID);
    this.pending.clear();
  }
}
