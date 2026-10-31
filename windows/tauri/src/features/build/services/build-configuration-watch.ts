import { getPathIdentity } from "@/utils/path-helpers";

export interface BuildConfigurationWatchInputs { watch: (paths: string[], changed: () => void) => { ready: Promise<boolean>; dispose: () => void } }

export interface BuildConfigurationSourceVersion { uri: string; revision: string }
export interface BuildConfigurationCheck { current: boolean; paths: string[] }
export interface BuildConfigurationWatch { recheck: () => void; dispose: () => Promise<void> }

/** Only native hashes cross IPC. Register first, then recheck to close the
 * read/lease gap; coalesce notifications and drain late reads when retired. */
export function watchBuildConfiguration(check: () => Promise<BuildConfigurationCheck>, changed: () => void,
  inputs: BuildConfigurationWatchInputs): BuildConfigurationWatch {
  let stopped = false, pending = false, initialized = false, pathsIdentity = "";
  const identity = (paths: string[]) => JSON.stringify([...new Set(paths.map(getPathIdentity))].sort());
  let lease: ReturnType<BuildConfigurationWatchInputs["watch"]> | undefined, running: Promise<void> | undefined;
  const recheck = () => {
    if (stopped) return;
    pending = true;
    if (!initialized || running) return;
    running = (async () => {
      while (pending && !stopped) {
        pending = false;
        try { const result = await check(); if (!stopped && (!result.current || identity(result.paths) !== pathsIdentity)) changed(); }
        catch { if (!stopped) changed(); }
      }
    })().finally(() => { running = undefined; });
  };
  const initial = (async () => {
    try {
      const result = await check();
      if (stopped) return;
      if (!result.current) { changed(); return; }
      pathsIdentity = identity(result.paths);
      lease = inputs.watch(result.paths, recheck);
      const registered = await lease.ready;
      if (stopped) return;
      if (!registered) changed(); else { initialized = true; recheck(); }
    } catch { if (!stopped) changed(); }
  })();
  return { recheck, dispose: async () => { stopped = true; pending = false; lease?.dispose(); await initial; await running; } };
}
