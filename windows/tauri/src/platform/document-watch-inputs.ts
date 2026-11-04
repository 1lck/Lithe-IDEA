import { getPathIdentity, normalizePath } from "@/utils/path-helpers";

export interface DocumentWatchInput {
  id: string; path: string; changed: () => void; registered: (success: boolean) => void;
}

/** Feature leases join the existing per-WebView document registration. They
 * cannot replace editor leases or create a second native filesystem watcher. */
export class DocumentWatchInputs {
  private sequence = 0;
  private readonly groups = new Map<number, DocumentWatchInput[]>();
  private readonly listeners = new Set<() => void>();
  subscribe = (callback: () => void): (() => void) => { this.listeners.add(callback); return () => { this.listeners.delete(callback); }; };
  snapshot = (): DocumentWatchInput[] => [...this.groups.values()].flat();

  watch(paths: string[], changed: () => void): { ready: Promise<boolean>; dispose: () => void } {
    const group = ++this.sequence, unique = [...new Map(paths.map(path => [getPathIdentity(path), normalizePath(path)])).values()];
    let resolve!: (success: boolean) => void;
    const ready = new Promise<boolean>(complete => { resolve = complete; });
    const remaining = new Set(unique.map((_, index) => index));
    this.groups.set(group, unique.map((path, index) => ({ id: `input:${group}:${index}`, path, changed,
      registered: success => { if (!success) resolve(false); else { remaining.delete(index); if (!remaining.size) resolve(true); } },
    })));
    if (!unique.length) resolve(true);
    this.publish();
    return { ready, dispose: () => { if (this.groups.delete(group)) { resolve(false); this.publish(); } } };
  }
  private publish(): void { for (const listener of this.listeners) listener(); }
}

export const documentWatchInputs = new DocumentWatchInputs();
