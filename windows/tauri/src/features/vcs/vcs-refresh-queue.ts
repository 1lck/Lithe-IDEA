/** One timer and one running passive scan. A storm records one dirty bit;
 * events during a scan produce at most one later scan, never a parallel scan. */
export class VcsRefreshQueue {
  #dirty = false;
  #running = false;
  #closed = false;
  #timer: (() => void) | null = null;
  constructor(
    private schedule: (callback: () => void) => () => void,
    private refresh: () => Promise<void>,
  ) {}
  changed() {
    if (this.#closed) return;
    this.#dirty = true;
    this.#schedule();
  }
  #schedule() {
    if (this.#closed || this.#running || this.#timer || !this.#dirty) return;
    this.#timer = this.schedule(() => {
      this.#timer = null;
      if (this.#closed) return;
      this.#dirty = false;
      this.#running = true;
      void this.refresh()
        .catch(() => {
          /* The root controller publishes failures. */
        })
        .finally(() => {
          this.#running = false;
          this.#schedule();
        });
    });
  }
  reset() {
    this.#dirty = false;
    this.#timer?.();
    this.#timer = null;
  }
  close() {
    this.#closed = true;
    this.reset();
  }
}
