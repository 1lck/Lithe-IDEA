export function deferUntilAfterNextPaint(callback: () => void): () => void {
  let state: "scheduled" | "completed" | "cancelled" = "scheduled";
  let firstFrameId: number | undefined;
  let secondFrameId: number | undefined;
  let timeoutId: ReturnType<typeof globalThis.setTimeout> | undefined;

  const run = () => {
    timeoutId = globalThis.setTimeout(() => {
      if (state === "scheduled") {
        state = "completed";
        callback();
      }
    }, 0);
  };

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    firstFrameId = window.requestAnimationFrame(() => {
      secondFrameId = window.requestAnimationFrame(run);
    });
  } else {
    run();
  }

  return () => {
    if (state !== "scheduled") return;
    state = "cancelled";
    if (firstFrameId !== undefined) {
      window.cancelAnimationFrame(firstFrameId);
    }
    if (secondFrameId !== undefined) {
      window.cancelAnimationFrame(secondFrameId);
    }
    if (timeoutId !== undefined) {
      globalThis.clearTimeout(timeoutId);
    }
  };
}
