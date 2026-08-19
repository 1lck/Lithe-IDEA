import { invoke } from "@/platform/tauri-core";

export interface ApplicationMemoryUsage {
  litheBytes: number;
  totalBytes: number;
}

export type MemorySampleReader = () => Promise<ApplicationMemoryUsage>;
export type MemorySampleConsumer = (usage: ApplicationMemoryUsage) => void;

export function readApplicationMemoryUsage(): Promise<ApplicationMemoryUsage> {
  return invoke<ApplicationMemoryUsage>("get_application_memory_usage");
}

export class ApplicationMemoryPoller {
  private active = false;
  private requestInFlight = false;

  constructor(
    private readonly consume: MemorySampleConsumer,
    private readonly read: MemorySampleReader = readApplicationMemoryUsage,
  ) {}

  start(): void {
    this.active = true;
  }

  stop(): void {
    this.active = false;
  }

  async poll(): Promise<void> {
    if (!this.active || this.requestInFlight) return;
    this.requestInFlight = true;
    try {
      const usage = await this.read();
      if (this.active) this.consume(usage);
    } catch {
      // The native host records the first sampling failure for the application
      // lifetime. Leaving React state unchanged preserves the last good sample.
    } finally {
      this.requestInFlight = false;
    }
  }
}
