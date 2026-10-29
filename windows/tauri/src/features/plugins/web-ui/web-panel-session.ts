export interface WebPanelBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}
export interface WebPanelLayout {
  bounds: WebPanelBounds;
  visible: boolean;
  focus: boolean;
}
export interface WebPanelPorts {
  mount(): Promise<{ mountId: string }>;
  layout(mountId: string, revision: number, layout: WebPanelLayout): Promise<void>;
  unmount(mountId: string): Promise<void>;
}
function failedMountReceipt(error: unknown): { mountId: string } | undefined {
  try {
    const failure: unknown = typeof error === "string" ? JSON.parse(error) : error;
    if (
      failure &&
      typeof failure === "object" &&
      "code" in failure &&
      failure.code === "plugin.web.cleanupFailed" &&
      "mountId" in failure &&
      typeof failure.mountId === "string" &&
      failure.mountId.length > 0
    )
      return { mountId: failure.mountId };
  } catch {
    /* Ordinary native failures have no pending cleanup receipt. */
  }
  return undefined;
}
type Phase = "opening" | "ready" | "failed" | "closing" | "cleanupFailed" | "closed";
const current = new Map<string, WebPanelSession>();
const retained = new Set<WebPanelSession>();
const listeners = new Set<() => void>();
let revision = 0;
function changed() {
  revision++;
  for (const listener of listeners) listener();
}
export const webPanelCleanup = {
  subscribe(listener: () => void) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
  revision: () => revision,
  pending: () => [...retained],
};

/** One DOM mount owns exactly one native receipt. A replacement waits for its
 * predecessor's cleanup; queued geometry never grants a late mount visibility. */
export class WebPanelSession {
  phase: Phase = "opening";
  private active = true;
  private receipt?: { mountId: string };
  private pending?: WebPanelLayout;
  private pumping?: Promise<void>;
  private closing?: Promise<void>;
  private layoutRevision = 0;
  readonly ready: Promise<void>;

  constructor(
    readonly key: string,
    readonly title: string,
    private readonly ports: WebPanelPorts,
    private readonly publish: (phase: Phase) => void,
    private previous?: WebPanelSession,
  ) {
    this.ready = Promise.resolve()
      .then(async () => {
        await this.previous?.dispose();
        this.previous = undefined;
        if (!this.active) return;
        try {
          this.receipt = await this.ports.mount();
        } catch (error: unknown) {
          this.receipt = failedMountReceipt(error);
          throw error;
        }
        if (!this.active) return;
        this.phase = "ready";
        this.publish(this.phase);
        void this.flush();
      })
      .catch((error: unknown) => {
        if (this.active) {
          this.phase = "failed";
          this.publish(this.phase);
        }
        throw error;
      });
    // The owner exposes ready to tests and callers; it also observes rejection
    // when a component is removed before the native command returns.
    void this.ready.catch(() => {});
  }

  update(layout: WebPanelLayout) {
    if (!this.active || this.phase === "failed") return;
    // Focus is a one-shot action. Later geometry must not erase an action that
    // has not reached the native owner; a hidden/occluded panel cancels it.
    this.pending = {
      ...layout,
      focus: layout.visible && (layout.focus || this.pending?.focus === true),
    };
    if (this.receipt) void this.flush();
  }

  private flush(): Promise<void> {
    if (this.pumping) return this.pumping;
    const task = (async () => {
      while (this.active && this.receipt && this.pending) {
        const next = this.pending;
        this.pending = undefined;
        await this.ports.layout(this.receipt.mountId, ++this.layoutRevision, next);
      }
    })()
      .catch(() => {
        if (this.active) {
          this.phase = "failed";
          this.publish(this.phase);
        }
      })
      .finally(() => {
        this.pumping = undefined;
        if (this.active && this.phase === "ready" && this.pending) void this.flush();
      });
    this.pumping = task;
    return task;
  }

  dispose(): Promise<void> {
    this.active = false;
    this.pending = undefined;
    if (this.phase === "closed") return Promise.resolve();
    if (this.closing) return this.closing;
    this.phase = "closing";
    changed();
    this.closing = (async () => {
      await this.ready.catch(() => {});
      await this.pumping;
      // A predecessor that could not close still owns its native view even
      // when this session's mount was never attempted.
      await this.previous?.dispose();
      this.previous = undefined;
      if (this.receipt) await this.ports.unmount(this.receipt.mountId);
      this.receipt = undefined;
      this.phase = "closed";
      retained.delete(this);
      if (current.get(this.key) === this) current.delete(this.key);
      changed();
    })()
      .catch((error: unknown) => {
        this.phase = "cleanupFailed";
        if (this.receipt) retained.add(this);
        changed();
        throw error;
      })
      .finally(() => {
        this.closing = undefined;
      });
    return this.closing;
  }
}

export function openWebPanelSession(
  key: string,
  title: string,
  ports: WebPanelPorts,
  publish: (phase: Phase) => void,
) {
  const session = new WebPanelSession(key, title, ports, publish, current.get(key));
  current.set(key, session);
  return session;
}
