// Measurement hooks injected before the Windows frontend loads. Self-contained:
// Playwright injects the source text, so no imports.
//
// Latency is the input event's timestamp to the start of the first animation
// frame after it: a frame that starts late means the main thread was busy or
// the result reached the screen a frame later than it could have.
(() => {
  if (window.__LITHE_PERF__) return;

  let armedAt = -1;
  let firstInputAfterArm = -1;

  const probe = {
    recordKeys: false,
    keyLatencies: [],
    frames: null,
    longTasks: [],

    startFrames() {
      const frames = [];
      probe.frames = frames;
      let previous = -1;
      const tick = (time) => {
        if (probe.frames !== frames) return;
        if (previous >= 0) frames.push(time - previous);
        previous = time;
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    },

    stopFrames() {
      const frames = probe.frames ?? [];
      probe.frames = null;
      return frames;
    },

    arm() {
      armedAt = performance.now();
      firstInputAfterArm = -1;
    },

    // Resolves with the time from the first input after `arm()` to the start of
    // the frame that first shows `predicate` true. The bounded deadline rejects
    // instead of leaving the scenario waiting forever.
    waitShown(selector, text, timeoutMilliseconds) {
      const deadline = performance.now() + timeoutMilliseconds;
      const matches = () => {
        for (const element of document.querySelectorAll(selector)) {
          if (element.getClientRects().length === 0) continue;
          if (text === null || (element.textContent ?? "").includes(text)) return true;
        }
        return false;
      };
      return new Promise((resolve, reject) => {
        const tick = () => {
          if (matches()) {
            const start = firstInputAfterArm >= 0 ? firstInputAfterArm : armedAt;
            armedAt = -1;
            resolve(performance.now() - start);
          } else if (performance.now() > deadline) {
            armedAt = -1;
            reject(new Error(`Timed out waiting for ${selector}${text ? ` containing "${text}"` : ""}`));
          } else {
            requestAnimationFrame(tick);
          }
        };
        requestAnimationFrame(tick);
      });
    },

    // Resolves once the main thread has been free of long tasks for `quietMilliseconds`.
    waitQuiet(quietMilliseconds, timeoutMilliseconds) {
      const started = performance.now();
      return new Promise((resolve) => {
        const check = () => {
          const now = performance.now();
          const last = probe.longTasks.at(-1);
          const lastEnd = last ? last.start + last.duration : 0;
          if (now - Math.max(lastEnd, started) >= quietMilliseconds || now - started > timeoutMilliseconds) {
            resolve(now - started);
          } else {
            setTimeout(check, 25);
          }
        };
        check();
      });
    },
  };

  const onInput = (event) => {
    if (armedAt >= 0 && firstInputAfterArm < 0) firstInputAfterArm = event.timeStamp;
    if (event.type === "keydown" && probe.recordKeys) {
      const started = event.timeStamp;
      requestAnimationFrame(() => probe.keyLatencies.push(performance.now() - started));
    }
  };
  for (const type of ["keydown", "pointerdown", "wheel"]) {
    window.addEventListener(type, onInput, { capture: true, passive: true });
  }

  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        probe.longTasks.push({ start: entry.startTime, duration: entry.duration });
      }
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // The Long Tasks API is missing outside Chromium; total blocking time then reads 0.
  }

  window.__LITHE_PERF__ = probe;
})();
