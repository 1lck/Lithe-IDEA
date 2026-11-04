import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { invoke } from "@/platform/tauri-core";
import { awaitBuildPreparation } from "./build-provider-operation";
import {
  requestCoreBuildProvider,
  startCoreBuildProvider,
  stopCoreBuildProvider,
  type CoreBuildProviderTarget,
} from "./lsp-core-adapter";

export interface BuildProviderLaunch {
  pluginId: string;
  buildSystemId: string;
  identity: unknown;
  serverPath: string;
  serverArgs: string[];
  initializationOptions?: unknown;
  environment: Record<string, string>;
}

interface BuildProviderPorts {
  resolve: (target: CoreBuildProviderTarget) => Promise<BuildProviderLaunch>;
  start: typeof startCoreBuildProvider;
  stop: typeof stopCoreBuildProvider;
  request: typeof requestCoreBuildProvider;
  guard: typeof pluginPlanGuard;
}

const nativePorts: BuildProviderPorts = {
  resolve: target => invoke("declarative_plugins_build_launch", { ...target }),
  start: startCoreBuildProvider,
  stop: stopCoreBuildProvider,
  request: requestCoreBuildProvider,
  guard: pluginPlanGuard,
};

function key(target: CoreBuildProviderTarget): string {
  const path = target.workspacePath.replace(/\\/g, "/");
  const workspace = /^(?:[A-Za-z]:\/|\/\/)/.test(path) ? path.toLowerCase() : path;
  return JSON.stringify([workspace, target.pluginId, target.buildSystemId]);
}

function cancelled(): Error & { code: string } {
  return Object.assign(new Error("Build Provider inputs changed."), { code: "cancelled" });
}

/** Serializes launch resolution/replacement, while requests run independently
 * through Core. Exact package/settings identity never crosses target owners.
 * Capability admission remains closed until the product workflows are wired. */
export class WindowsBuildProviderSessions {
  private readonly launches = new Map<string, string>();
  private readonly preparing = new Map<string, Promise<unknown>>();
  private readonly stopping = new Map<string, Promise<void>>();
  private readonly generations = new Map<string, number>();
  private readonly failedStops = new Set<string>();

  constructor(private readonly ports: BuildProviderPorts = nativePorts) {}

  async send<T>(target: CoreBuildProviderTarget, request: Parameters<typeof requestCoreBuildProvider<T>>[1]): Promise<T> {
    request.signal?.throwIfAborted();
    const owner = key(target), generation = this.generations.get(owner) ?? 0;
    if (this.stopping.has(owner) || this.failedStops.has(owner)) throw cancelled();
    const guard = this.ports.guard();
    const current = () => {
      request.signal?.throwIfAborted();
      guard(target.pluginId);
      if ((this.generations.get(owner) ?? 0) !== generation || this.stopping.has(owner) || this.failedStops.has(owner)) throw cancelled();
    };
    const previous = this.preparing.get(owner) ?? Promise.resolve();
    const preparing = previous.catch(() => undefined).then(async () => {
      current();
      const launch = await this.ports.resolve(target);
      current();
      if (launch.pluginId !== target.pluginId || launch.buildSystemId !== target.buildSystemId) {
        throw new Error("The native launch belongs to another Build Provider.");
      }
      if (!launch.identity || typeof launch.identity !== "object") throw new Error("The native Build Provider launch has no identity.");
      const identity = JSON.stringify([launch.identity, launch.serverPath, launch.serverArgs,
        launch.initializationOptions ?? null, launch.environment]);
      if (this.launches.has(owner) && this.launches.get(owner) !== identity) {
        try { await this.ports.stop(target); }
        catch (error) { this.failedStops.add(owner); throw error; }
        current();
      }
      await this.ports.start(target, launch);
      this.launches.set(owner, identity);
      current();
      return identity;
    });
    this.preparing.set(owner, preparing);
    const releasePreparation = () => {
      if (this.preparing.get(owner) === preparing) this.preparing.delete(owner);
    };
    void preparing.then(releasePreparation, releasePreparation);
    const identity = await awaitBuildPreparation(preparing, request.signal);
    current();
    if (this.launches.get(owner) !== identity) throw cancelled();
    return await this.ports.request<T>(target, request);
  }

  async stop(target: CoreBuildProviderTarget): Promise<void> {
    const owner = key(target);
    let stopped = this.stopping.get(owner);
    if (!stopped) {
      this.generations.set(owner, (this.generations.get(owner) ?? 0) + 1);
      const pending = this.preparing.get(owner);
      stopped = (async () => {
        await this.ports.stop(target);
        if (pending) {
          await pending.catch(() => undefined);
          await this.ports.stop(target);
        }
        this.launches.delete(owner);
        this.failedStops.delete(owner);
      })().catch(error => { this.failedStops.add(owner); throw error; })
        .finally(() => { if (this.stopping.get(owner) === stopped) this.stopping.delete(owner); });
      this.stopping.set(owner, stopped);
    }
    await stopped;
  }
}

export const windowsBuildProviders = new WindowsBuildProviderSessions();
