import { invoke } from "@/platform/tauri-core";

const MAX_ACTIVE_RENDERS = 2;
const MAX_QUEUED_RENDERS = 64;
interface RenderJob { source: string; signal?: AbortSignal; resolve: (html: string) => void; reject: (error: unknown) => void; abort: () => void }
const queue: RenderJob[] = [];
let active = 0;
const capacityWaiters = new Set<() => void>();
const aborted = () => new DOMException("Markdown render cancelled", "AbortError");
class MarkdownQueueFull extends Error {}
function notifyCapacity(): void {
  // One freed slot admits one waiting view. Waking every view on each
  // completion would repeatedly reschedule an entire large notebook.
  capacityWaiters.values().next().value?.();
}
function waitForCapacity(signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(aborted());
  if (queue.length < MAX_QUEUED_RENDERS) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cleanup = () => { capacityWaiters.delete(onCapacity); signal?.removeEventListener("abort", onAbort); };
    const onCapacity = () => { cleanup(); resolve(); };
    const onAbort = () => { cleanup(); reject(aborted()); };
    capacityWaiters.add(onCapacity);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
function drain(): void {
  while (active < MAX_ACTIVE_RENDERS && queue.length) {
    const job = queue.shift()!;
    notifyCapacity();
    job.signal?.removeEventListener("abort", job.abort);
    if (job.signal?.aborted) { job.reject(aborted()); continue; }
    active++;
    // Running native work retains its slot until it settles. Aborting a view
    // removes queued work, but cannot create unlimited native blocking tasks.
    void invoke<{ html: string }>("markdown.render", { source: job.source }).then(
      result => job.signal?.aborted ? job.reject(aborted()) : job.resolve(result.html),
      job.reject,
    ).finally(() => { active--; drain(); });
  }
}
/** Core owns syntax and sanitization; this dispatcher only bounds IPC work. */
export function renderMarkdown(source: string, signal?: AbortSignal): Promise<string> {
  if (signal?.aborted) return Promise.reject(aborted());
  if (queue.length >= MAX_QUEUED_RENDERS) return Promise.reject(new MarkdownQueueFull("Markdown render queue capacity exceeded"));
  return new Promise((resolve, reject) => {
    const job: RenderJob = { source, signal, resolve, reject, abort: () => {
      const index = queue.indexOf(job);
      if (index >= 0) { queue.splice(index, 1); notifyCapacity(); reject(aborted()); }
    } };
    signal?.addEventListener("abort", job.abort, { once: true });
    queue.push(job); drain();
  });
}

/** Mounted views wait for capacity without growing the native work queue. */
export async function renderMarkdownWhenReady(source: string, signal?: AbortSignal): Promise<string> {
  for (;;) {
    try {
      return await renderMarkdown(source, signal);
    } catch (error) {
      if (!(error instanceof MarkdownQueueFull)) throw error;
      await waitForCapacity(signal);
    }
  }
}
