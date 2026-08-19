import { describe, expect, test } from "bun:test";
import {
  FPS_ANOMALY_ENTER_DURATION_MS,
  FpsAnomalyDetector,
} from "./fps-monitor";

describe("FPS anomaly detector", () => {
  test("requires three seconds below the entry threshold and summarizes recovery", () => {
    const detector = new FpsAnomalyDetector();
    let now = 0;

    for (let index = 0; index < FPS_ANOMALY_ENTER_DURATION_MS / 1_000; index += 1) {
      now += 1_000;
      expect(detector.addBucket(40, 1_000, now, false)).toEqual([]);
    }

    now += 1_000;
    const recovered = detector.addBucket(55, 1_000, now, false);
    expect(recovered).toHaveLength(1);
    expect(recovered[0]?.message).toBe("Frame drop recovered");
    expect(recovered[0]?.payload.fps_min).toBe(40);
    expect(recovered[0]?.payload.duration_ms).toBe(4_000);
  });

  test("emits progress while an anomaly remains active", () => {
    const detector = new FpsAnomalyDetector();
    let now = 0;
    const events = [];

    for (let index = 0; index < 13; index += 1) {
      now += 1_000;
      events.push(...detector.addBucket(30, 1_000, now, false));
    }

    expect(events.some((event) => event.message === "Frame drop ongoing")).toBe(true);
  });

  test("diagnostic mode emits a ten second heartbeat", () => {
    const detector = new FpsAnomalyDetector();
    let now = 0;
    const events = [];

    for (let index = 0; index < 10; index += 1) {
      now += 1_000;
      events.push(...detector.addBucket(60, 1_000, now, true));
    }

    const heartbeat = events.find((event) => event.scope === "perf.heartbeat");
    expect(heartbeat?.level).toBe("debug");
    expect(heartbeat?.payload.fps_avg).toBe(60);
  });

  test("visibility pause resets the entry window", () => {
    const detector = new FpsAnomalyDetector();
    detector.addBucket(30, 1_000, 1_000, false);
    detector.addBucket(30, 1_000, 2_000, false);
    detector.pause();

    expect(detector.addBucket(30, 1_000, 3_000, false)).toEqual([]);
    expect(detector.addBucket(55, 1_000, 4_000, false)).toEqual([]);
  });
});
