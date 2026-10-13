import { describe, expect, test } from "bun:test";
import policy from "../../../../../../shared/contracts/agent-turn-policy.json";
import { AcpActivityMonitor, type ActivityScheduler } from "./acp-activity-monitor";

class ManualTimer implements ActivityScheduler {
  private now = 0;
  private callbacks = new Map<() => void, number>();

  schedule(callback: () => void, delay: number): () => void {
    this.callbacks.set(callback, this.now + delay);
    return () => this.callbacks.delete(callback);
  }

  advance(milliseconds: number): void {
    this.now += milliseconds;
    for (const [callback, deadline] of this.callbacks) {
      if (deadline <= this.now) {
        this.callbacks.delete(callback);
        callback();
      }
    }
  }

  get pending(): number {
    return this.callbacks.size;
  }
}

describe("ACP quiet activity advisory", () => {
  test("long silence produces one notice and progress rearms it", () => {
    const timer = new ManualTimer();
    const notices: boolean[] = [];
    const monitor = new AcpActivityMonitor((quiet) => notices.push(quiet), timer);
    try {
      monitor.start();
      timer.advance(policy.quietNoticeMilliseconds - 1);
      expect(notices).toEqual([]);
      timer.advance(1);
      expect(notices).toEqual([true]);
      timer.advance(3_600_000);
      expect(notices).toEqual([true]);
      monitor.progress();
      expect(notices).toEqual([true, false]);
      timer.advance(policy.quietNoticeMilliseconds);
      expect(notices).toEqual([true, false, true]);
    } finally {
      monitor.stop();
    }
    expect(timer.pending).toBe(0);
  });

  test("all permissions can wait indefinitely before the advisory resumes", () => {
    const timer = new ManualTimer();
    const notices: boolean[] = [];
    const monitor = new AcpActivityMonitor((quiet) => notices.push(quiet), timer);
    try {
      monitor.start();
      monitor.permissionRequested("a");
      monitor.permissionRequested("b");
      timer.advance(3_600_000);
      expect(notices).toEqual([]);
      monitor.permissionAnswered("a");
      timer.advance(3_600_000);
      expect(notices).toEqual([]);
      monitor.permissionAnswered("b");
      timer.advance(policy.quietNoticeMilliseconds);
      expect(notices).toEqual([true]);
    } finally {
      monitor.stop();
    }
    expect(timer.pending).toBe(0);
  });

  test("stopping clears the notice and leaves no timer in the next turn", () => {
    const timer = new ManualTimer();
    const notices: boolean[] = [];
    const monitor = new AcpActivityMonitor((quiet) => notices.push(quiet), timer);
    try {
      monitor.start();
      timer.advance(policy.quietNoticeMilliseconds);
      monitor.stop();
      timer.advance(3_600_000);
      expect(notices).toEqual([true, false]);
      expect(timer.pending).toBe(0);
      monitor.start();
      monitor.progress();
      expect(timer.pending).toBe(1);
    } finally {
      monitor.stop();
    }
    expect(timer.pending).toBe(0);
  });
});
