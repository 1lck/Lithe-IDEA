import policy from "../../../../../../shared/contracts/agent-turn-policy.json";

export interface ActivityScheduler {
  schedule: (callback: () => void, delay: number) => () => void;
}

const scheduler: ActivityScheduler = {
  schedule: (callback, delay) => {
    const timer = setTimeout(callback, delay);
    return () => clearTimeout(timer);
  },
};

/** Advisory only: quiet tools and reasoning keep their original prompt alive. */
export class AcpActivityMonitor {
  private cancelTimer: (() => void) | undefined;
  private permissions = new Set<string>();
  private active = false;
  private quiet = false;

  constructor(
    private readonly onQuiet: (quiet: boolean) => void,
    private readonly timer: ActivityScheduler = scheduler,
  ) {}

  start(): void {
    this.stop();
    this.active = true;
    this.progress();
  }

  progress(): void {
    this.cancelTimer?.();
    this.cancelTimer = undefined;
    this.setQuiet(false);
    if (!this.active || this.permissions.size > 0) return;
    this.cancelTimer = this.timer.schedule(() => {
      this.cancelTimer = undefined;
      if (this.active && this.permissions.size === 0) this.setQuiet(true);
    }, policy.quietNoticeMilliseconds);
  }

  permissionRequested(id: string): void {
    this.permissions.add(id);
    this.progress();
  }

  permissionAnswered(id: string): void {
    this.permissions.delete(id);
    this.progress();
  }

  stop(): void {
    this.active = false;
    this.cancelTimer?.();
    this.cancelTimer = undefined;
    this.permissions.clear();
    this.setQuiet(false);
  }

  private setQuiet(quiet: boolean): void {
    if (this.quiet === quiet) return;
    this.quiet = quiet;
    this.onQuiet(quiet);
  }
}
