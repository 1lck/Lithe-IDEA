export const FPS_ANOMALY_ENTER_THRESHOLD = 45;
export const FPS_ANOMALY_EXIT_THRESHOLD = 50;
export const FPS_ANOMALY_ENTER_DURATION_MS = 3_000;
export const FPS_PROGRESS_INTERVAL_MS = 10_000;
export const FPS_DIAGNOSTIC_HEARTBEAT_MS = 10_000;

export interface FpsLogEvent {
  level: "debug" | "warn";
  scope: "perf.fps" | "perf.heartbeat";
  message: string;
  payload: Record<string, number | string>;
}

interface FpsWindow {
  frames: number;
  elapsedMs: number;
  minFps: number;
}

function emptyWindow(): FpsWindow {
  return { frames: 0, elapsedMs: 0, minFps: Number.POSITIVE_INFINITY };
}

function averageFps(window: FpsWindow) {
  return window.elapsedMs > 0 ? (window.frames * 1_000) / window.elapsedMs : 0;
}

function rounded(value: number) {
  return Math.round(value * 10) / 10;
}

export class FpsAnomalyDetector {
  private candidate = emptyWindow();
  private anomaly: FpsWindow | null = null;
  private anomalyStartedAt = 0;
  private lastProgressAt = 0;
  private heartbeat = emptyWindow();
  private heartbeatStartedAt: number | null = null;

  addBucket(
    frames: number,
    elapsedMs: number,
    now: number,
    diagnosticEnabled: boolean,
  ): FpsLogEvent[] {
    const events: FpsLogEvent[] = [];
    const fps = elapsedMs > 0 ? (frames * 1_000) / elapsedMs : 0;

    if (diagnosticEnabled) {
      if (this.heartbeatStartedAt === null) this.heartbeatStartedAt = now - elapsedMs;
      this.addToWindow(this.heartbeat, frames, elapsedMs, fps);
      if (now - this.heartbeatStartedAt >= FPS_DIAGNOSTIC_HEARTBEAT_MS) {
        events.push({
          level: "debug",
          scope: "perf.heartbeat",
          message: "FPS diagnostic heartbeat",
          payload: {
            fps_avg: rounded(averageFps(this.heartbeat)),
            fps_min: rounded(this.heartbeat.minFps),
            duration_ms: Math.round(this.heartbeat.elapsedMs),
          },
        });
        this.heartbeat = emptyWindow();
        this.heartbeatStartedAt = now;
      }
    } else {
      this.heartbeat = emptyWindow();
      this.heartbeatStartedAt = null;
    }

    if (this.anomaly) {
      this.addToWindow(this.anomaly, frames, elapsedMs, fps);
      if (fps >= FPS_ANOMALY_EXIT_THRESHOLD) {
        events.push(this.anomalyEvent("Frame drop recovered", now));
        this.resetAnomaly();
      } else if (now - this.lastProgressAt >= FPS_PROGRESS_INTERVAL_MS) {
        events.push(this.anomalyEvent("Frame drop ongoing", now));
        this.lastProgressAt = now;
      }
      return events;
    }

    if (fps < FPS_ANOMALY_ENTER_THRESHOLD) {
      if (this.candidate.elapsedMs === 0) this.anomalyStartedAt = now - elapsedMs;
      this.addToWindow(this.candidate, frames, elapsedMs, fps);
      if (this.candidate.elapsedMs >= FPS_ANOMALY_ENTER_DURATION_MS) {
        this.anomaly = this.candidate;
        this.candidate = emptyWindow();
        this.lastProgressAt = now;
      }
    } else {
      this.candidate = emptyWindow();
      this.anomalyStartedAt = 0;
    }
    return events;
  }

  pause() {
    this.candidate = emptyWindow();
    this.heartbeat = emptyWindow();
    this.heartbeatStartedAt = null;
    if (!this.anomaly) this.anomalyStartedAt = 0;
  }

  private addToWindow(window: FpsWindow, frames: number, elapsedMs: number, fps: number) {
    window.frames += frames;
    window.elapsedMs += elapsedMs;
    window.minFps = Math.min(window.minFps, fps);
  }

  private anomalyEvent(message: string, now: number): FpsLogEvent {
    const anomaly = this.anomaly ?? this.candidate;
    return {
      level: "warn",
      scope: "perf.fps",
      message,
      payload: {
        fps_avg: rounded(averageFps(anomaly)),
        fps_min: rounded(anomaly.minFps),
        duration_ms: Math.max(Math.round(anomaly.elapsedMs), Math.round(now - this.anomalyStartedAt)),
      },
    };
  }

  private resetAnomaly() {
    this.candidate = emptyWindow();
    this.anomaly = null;
    this.anomalyStartedAt = 0;
    this.lastProgressAt = 0;
  }
}

export function startFpsLogging(
  emit: (event: FpsLogEvent) => void,
  isDiagnosticEnabled: () => boolean,
) {
  if (typeof window === "undefined" || typeof document === "undefined") return () => {};

  const detector = new FpsAnomalyDetector();
  let frameId = 0;
  let bucketStartedAt = performance.now();
  let frames = 0;

  const resetForVisibility = () => {
    detector.pause();
    bucketStartedAt = performance.now();
    frames = 0;
  };
  document.addEventListener("visibilitychange", resetForVisibility);

  const record = (now: number) => {
    if (document.visibilityState !== "visible") {
      detector.pause();
      bucketStartedAt = now;
      frames = 0;
      frameId = window.requestAnimationFrame(record);
      return;
    }

    frames += 1;
    const elapsedMs = now - bucketStartedAt;
    if (elapsedMs >= 1_000) {
      const events = detector.addBucket(frames, elapsedMs, now, isDiagnosticEnabled());
      for (const event of events) emit(event);
      bucketStartedAt = now;
      frames = 0;
    }
    frameId = window.requestAnimationFrame(record);
  };

  frameId = window.requestAnimationFrame(record);
  return () => {
    window.cancelAnimationFrame(frameId);
    document.removeEventListener("visibilitychange", resetForVisibility);
  };
}
