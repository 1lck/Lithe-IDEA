const SYNCHRONIZED_OUTPUT_ENTER = new Uint8Array([0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x68]);
const SYNCHRONIZED_OUTPUT_EXIT = new Uint8Array([0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x6c]);
const SYNCHRONIZED_OUTPUT_MARKER_LENGTH = SYNCHRONIZED_OUTPUT_ENTER.length;
// Keep a short burst together so xterm paints a complete redraw state instead
// of exposing every intermediate clear-and-redraw frame.
const DEFAULT_SETTLE_DELAY_MS = 40;

interface PendingWrite {
  data: Uint8Array;
  onComplete: () => void;
}

export interface TerminalOutputWriteBufferOptions {
  write: (data: Uint8Array, onComplete: () => void) => void;
  scheduleFlush?: (callback: () => void, delayMs: number) => unknown;
  cancelFlush?: (handle: unknown) => void;
  settleDelayMs?: number;
}

/**
 * Keeps a DEC 2026 synchronized redraw atomic at the xterm write boundary.
 *
 * xterm can defer canvas painting while synchronized output is active, but a
 * fragmented ED3/exit/trailing-output sequence can still expose an
 * intermediate scrollback position between two writes. Ordinary output keeps
 * its existing immediate path; only synchronized output is held briefly until
 * the next frame can be included.
 */
export class TerminalOutputWriteBuffer {
  private readonly write: TerminalOutputWriteBufferOptions["write"];
  private readonly scheduleFlush: NonNullable<TerminalOutputWriteBufferOptions["scheduleFlush"]>;
  private readonly cancelFlush: NonNullable<TerminalOutputWriteBufferOptions["cancelFlush"]>;
  private readonly settleDelayMs: number;
  private readonly pending: PendingWrite[] = [];
  private scanTail = new Uint8Array(0);
  private synchronizedOutput = false;
  private awaitingTrailingOutput = false;
  private scheduledFlush: unknown;
  private disposed = false;

  public constructor(options: TerminalOutputWriteBufferOptions) {
    this.write = options.write;
    this.scheduleFlush =
      options.scheduleFlush ?? ((callback, delayMs) => setTimeout(callback, delayMs));
    this.cancelFlush =
      options.cancelFlush ?? ((handle) => clearTimeout(handle as ReturnType<typeof setTimeout>));
    this.settleDelayMs = options.settleDelayMs ?? DEFAULT_SETTLE_DELAY_MS;
  }

  public enqueue(data: Uint8Array, onComplete: () => void): void {
    if (this.disposed) {
      onComplete();
      return;
    }

    const containsSynchronizedMarker = this.containsSynchronizedMarker(data);
    const shouldBuffer =
      this.pending.length > 0 ||
      this.synchronizedOutput ||
      this.awaitingTrailingOutput ||
      containsSynchronizedMarker;

    if (!shouldBuffer) {
      this.updateProtocolState(data);
      this.write(data, onComplete);
      return;
    }

    this.pending.push({ data: data.slice(), onComplete });
    this.updateProtocolState(data);
  }

  public flush(): void {
    this.cancelScheduledFlush();
    this.flushPending();
  }

  public dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.flush();
  }

  private containsSynchronizedMarker(data: Uint8Array): boolean {
    const combined = this.concat(this.scanTail, data);
    return (
      this.indexOf(combined, SYNCHRONIZED_OUTPUT_ENTER) !== -1 ||
      this.indexOf(combined, SYNCHRONIZED_OUTPUT_EXIT) !== -1
    );
  }

  private updateProtocolState(data: Uint8Array): void {
    const combined = this.concat(this.scanTail, data);
    let index = 0;

    while (index <= combined.length - SYNCHRONIZED_OUTPUT_MARKER_LENGTH) {
      const enterIndex = this.indexOf(combined, SYNCHRONIZED_OUTPUT_ENTER, index);
      const exitIndex = this.indexOf(combined, SYNCHRONIZED_OUTPUT_EXIT, index);
      const nextIndex = this.nextMarkerIndex(enterIndex, exitIndex);
      if (nextIndex === -1) break;

      if (enterIndex !== -1 && enterIndex === nextIndex) {
        this.synchronizedOutput = true;
        this.awaitingTrailingOutput = false;
        this.cancelScheduledFlush();
      } else {
        this.synchronizedOutput = false;
        this.awaitingTrailingOutput = true;
        this.schedulePendingFlush();
      }

      index = nextIndex + SYNCHRONIZED_OUTPUT_MARKER_LENGTH;
    }

    this.scanTail = combined.slice(
      Math.max(0, combined.length - SYNCHRONIZED_OUTPUT_MARKER_LENGTH + 1),
    );
  }

  private schedulePendingFlush(): void {
    if (this.scheduledFlush !== undefined) return;

    this.scheduledFlush = this.scheduleFlush(() => {
      this.scheduledFlush = undefined;
      this.awaitingTrailingOutput = false;
      if (!this.synchronizedOutput) this.flushPending();
    }, this.settleDelayMs);
  }

  private cancelScheduledFlush(): void {
    if (this.scheduledFlush === undefined) return;
    this.cancelFlush(this.scheduledFlush);
    this.scheduledFlush = undefined;
  }

  private flushPending(): void {
    if (this.pending.length === 0) return;

    const writes = this.pending.splice(0);
    const data = this.concatMany(writes.map((write) => write.data));
    this.write(data, () => {
      for (const write of writes) write.onComplete();
    });
  }

  private indexOf(data: Uint8Array, needle: Uint8Array, fromIndex = 0): number {
    outer: for (let index = fromIndex; index <= data.length - needle.length; index++) {
      for (let offset = 0; offset < needle.length; offset++) {
        if (data[index + offset] !== needle[offset]) continue outer;
      }
      return index;
    }
    return -1;
  }

  private nextMarkerIndex(enterIndex: number, exitIndex: number): number {
    if (enterIndex === -1) return exitIndex;
    if (exitIndex === -1) return enterIndex;
    return Math.min(enterIndex, exitIndex);
  }

  private concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left);
    result.set(right, left.length);
    return result;
  }

  private concatMany(chunks: Uint8Array[]): Uint8Array {
    const length = chunks.reduce((total, chunk) => total + chunk.length, 0);
    const result = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }
}
