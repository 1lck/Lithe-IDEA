import { invoke } from "@/platform/tauri-core";

const MAX_ACTIVE_RENDERS = 2;
const MAX_QUEUED_RENDERS = 64;
interface RenderJob { source: string; signal?: AbortSignal; resolve: (html: string) => void; reject: (error: unknown) => void; abort: () => void }
const queue: RenderJob[] = [];
let active = 0;
const aborted = () => new DOMException("Markdown render cancelled", "AbortError");
function drain(): void {
  while (active < MAX_ACTIVE_RENDERS && queue.length) {
    const job = queue.shift()!;
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
  if (queue.length >= MAX_QUEUED_RENDERS) return Promise.reject(new Error("Markdown render queue capacity exceeded"));
  return new Promise((resolve, reject) => {
    const job: RenderJob = { source, signal, resolve, reject, abort: () => {
      const index = queue.indexOf(job);
      if (index >= 0) { queue.splice(index, 1); reject(aborted()); }
    } };
    signal?.addEventListener("abort", job.abort, { once: true });
    queue.push(job); drain();
  });
}
