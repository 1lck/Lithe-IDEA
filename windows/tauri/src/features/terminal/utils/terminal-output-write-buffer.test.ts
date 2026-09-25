import { describe, expect, test } from "bun:test";
import { TerminalOutputWriteBuffer } from "./terminal-output-write-buffer";

const encoder = new TextEncoder();

const enter = encoder.encode("\x1b[?2026h");
const exit = encoder.encode("\x1b[?2026l");

function bytes(text: string): Uint8Array {
  return encoder.encode(text);
}

function concat(...chunks: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(chunks.reduce((length, chunk) => length + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

interface ScheduledFlush {
  callback: () => void;
  delayMs: number;
}

function createManualScheduler() {
  const scheduled: ScheduledFlush[] = [];
  return {
    scheduled,
    scheduleFlush: (callback: () => void, delayMs: number) => {
      const handle = { callback, delayMs };
      scheduled.push(handle);
      return handle;
    },
    cancelFlush: (handle: unknown) => {
      const index = scheduled.indexOf(handle as ScheduledFlush);
      if (index !== -1) scheduled.splice(index, 1);
    },
  };
}

describe("TerminalOutputWriteBuffer", () => {
  test("writes ordinary output immediately", () => {
    const writes: Uint8Array[] = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
    });

    buffer.enqueue(bytes("prompt> "), () => {});

    expect(writes.map((data) => new TextDecoder().decode(data))).toEqual(["prompt> "]);
  });

  test("keeps a fragmented synchronized redraw and its trailing output in one write", () => {
    const writes: Uint8Array[] = [];
    const callbacks: string[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(enter, () => callbacks.push("enter"));
    buffer.enqueue(bytes("\x1b[2J\x1b[3Jcontent"), () => callbacks.push("content"));
    buffer.enqueue(exit, () => callbacks.push("exit"));
    buffer.enqueue(bytes("\x1b[39m"), () => callbacks.push("trailing"));

    expect(writes).toHaveLength(0);
    expect(scheduler.scheduled).toHaveLength(1);

    scheduler.scheduled[0].callback();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(
      concat(enter, bytes("\x1b[2J\x1b[3Jcontent"), exit, bytes("\x1b[39m")),
    );
    expect(callbacks).toEqual(["enter", "content", "exit", "trailing"]);
  });

  test("keeps completion callbacks pending until the merged write completes", () => {
    const writes: Uint8Array[] = [];
    const callbacks: string[] = [];
    const scheduler = createManualScheduler();
    let completeWrite: (() => void) | undefined;
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        completeWrite = onComplete;
      },
      ...scheduler,
    });

    buffer.enqueue(enter, () => callbacks.push("enter"));
    buffer.enqueue(bytes("frame"), () => callbacks.push("frame"));
    buffer.enqueue(exit, () => callbacks.push("exit"));

    scheduler.scheduled[0].callback();

    expect(writes).toHaveLength(1);
    expect(callbacks).toEqual([]);

    completeWrite?.();

    expect(callbacks).toEqual(["enter", "frame", "exit"]);
  });
  test("coalesces adjacent synchronized redraw frames within the settle window", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      settleDelayMs: 40,
      ...scheduler,
    });

    buffer.enqueue(concat(enter, bytes("first"), exit), () => {});
    expect(scheduler.scheduled).toHaveLength(1);

    buffer.enqueue(concat(enter, bytes("second"), exit), () => {});
    expect(writes).toHaveLength(0);
    expect(scheduler.scheduled).toHaveLength(1);

    scheduler.scheduled[0].callback();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(concat(enter, bytes("first"), exit, enter, bytes("second"), exit));
  });
  test("recognizes synchronized markers split across output chunks", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(bytes("\x1b[?2026"), () => {});
    buffer.enqueue(bytes("hframe\x1b[?2026"), () => {});
    buffer.enqueue(bytes("l"), () => {});

    expect(writes).toHaveLength(1);
    expect(scheduler.scheduled).toHaveLength(1);
    scheduler.scheduled[0].callback();
    expect(writes).toHaveLength(2);
    expect(writes[1]).toEqual(concat(bytes("hframe\x1b[?2026"), bytes("l")));
  });

  test("returns to immediate writes after a synchronized frame is flushed", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(concat(enter, bytes("frame"), exit), () => {});
    scheduler.scheduled[0].callback();
    buffer.enqueue(bytes("prompt> "), () => {});

    expect(writes).toEqual([concat(enter, bytes("frame"), exit), bytes("prompt> ")]);
  });

  test("flushes pending output before a terminal error is written", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(concat(enter, bytes("frame"), exit), () => {});
    const writeTerminalError = () => {
      buffer.flush();
      writes.push(bytes("error"));
    };

    writeTerminalError();

    expect(writes).toEqual([concat(enter, bytes("frame"), exit), bytes("error")]);
    expect(scheduler.scheduled).toHaveLength(0);
  });

  test("flushes a synchronized frame when the end marker never arrives", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const callbacks: string[] = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      synchronizedOutputTimeoutMs: 1_000,
      ...scheduler,
    });

    buffer.enqueue(enter, () => callbacks.push("enter"));
    buffer.enqueue(bytes("hello"), () => callbacks.push("hello"));

    expect(writes).toHaveLength(0);
    expect(scheduler.scheduled).toHaveLength(1);
    expect(scheduler.scheduled[0].delayMs).toBe(1_000);

    scheduler.scheduled[0].callback();

    expect(writes).toEqual([concat(enter, bytes("hello"))]);
    expect(callbacks).toEqual(["enter", "hello"]);

    buffer.enqueue(bytes("prompt> "), () => {});
    expect(writes).toHaveLength(2);
  });

  test("flushes a start marker even when no following output arrives", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(enter, () => {});

    expect(writes).toHaveLength(0);
    expect(scheduler.scheduled).toHaveLength(1);
    expect(scheduler.scheduled[0].delayMs).toBe(1_000);

    scheduler.scheduled[0].callback();

    expect(writes).toEqual([enter]);
  });

  test("flushes a large synchronized frame at the pending-byte watermark", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      maxPendingBytes: enter.byteLength + 4,
      ...scheduler,
    });

    buffer.enqueue(enter, () => {});
    buffer.enqueue(bytes("1234"), () => {});

    expect(writes).toEqual([concat(enter, bytes("1234"))]);
    expect(buffer.hasPendingWrites).toBe(false);
    expect(scheduler.scheduled).toHaveLength(1);
  });

  test("flushes pending output when disposed", () => {
    const writes: Uint8Array[] = [];
    const scheduler = createManualScheduler();
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      ...scheduler,
    });

    buffer.enqueue(enter, () => {});
    buffer.enqueue(exit, () => {});
    buffer.dispose();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(concat(enter, exit));
  });
});
