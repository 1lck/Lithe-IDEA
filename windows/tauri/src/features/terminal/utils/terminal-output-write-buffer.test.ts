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
    const scheduled: Array<() => void> = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: (handle) => {
        const index = scheduled.indexOf(handle as () => void);
        if (index !== -1) scheduled.splice(index, 1);
      },
    });

    buffer.enqueue(enter, () => callbacks.push("enter"));
    buffer.enqueue(bytes("\x1b[2J\x1b[3Jcontent"), () => callbacks.push("content"));
    buffer.enqueue(exit, () => callbacks.push("exit"));
    buffer.enqueue(bytes("\x1b[39m"), () => callbacks.push("trailing"));

    expect(writes).toHaveLength(0);
    expect(scheduled).toHaveLength(1);

    scheduled[0]();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(
      concat(enter, bytes("\x1b[2J\x1b[3Jcontent"), exit, bytes("\x1b[39m")),
    );
    expect(callbacks).toEqual(["enter", "content", "exit", "trailing"]);
  });

  test("keeps completion callbacks pending until the merged write completes", () => {
    const writes: Uint8Array[] = [];
    const callbacks: string[] = [];
    const scheduled: Array<() => void> = [];
    let completeWrite: (() => void) | undefined;
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        completeWrite = onComplete;
      },
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: () => {},
    });

    buffer.enqueue(enter, () => callbacks.push("enter"));
    buffer.enqueue(bytes("frame"), () => callbacks.push("frame"));
    buffer.enqueue(exit, () => callbacks.push("exit"));

    scheduled[0]();

    expect(writes).toHaveLength(1);
    expect(callbacks).toEqual([]);

    completeWrite?.();

    expect(callbacks).toEqual(["enter", "frame", "exit"]);
  });
  test("coalesces adjacent synchronized redraw frames within the settle window", () => {
    const writes: Uint8Array[] = [];
    const scheduled: Array<() => void> = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      settleDelayMs: 40,
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: (handle) => {
        const index = scheduled.indexOf(handle as () => void);
        if (index !== -1) scheduled.splice(index, 1);
      },
    });

    buffer.enqueue(concat(enter, bytes("first"), exit), () => {});
    expect(scheduled).toHaveLength(1);

    buffer.enqueue(concat(enter, bytes("second"), exit), () => {});
    expect(writes).toHaveLength(0);
    expect(scheduled).toHaveLength(1);

    scheduled[0]();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(concat(enter, bytes("first"), exit, enter, bytes("second"), exit));
  });
  test("recognizes synchronized markers split across output chunks", () => {
    const writes: Uint8Array[] = [];
    const scheduled: Array<() => void> = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: () => {},
    });

    buffer.enqueue(bytes("\x1b[?2026"), () => {});
    buffer.enqueue(bytes("hframe\x1b[?2026"), () => {});
    buffer.enqueue(bytes("l"), () => {});

    expect(writes).toHaveLength(1);
    expect(scheduled).toHaveLength(1);
    scheduled[0]();
    expect(writes).toHaveLength(2);
    expect(writes[1]).toEqual(concat(bytes("hframe\x1b[?2026"), bytes("l")));
  });

  test("returns to immediate writes after a synchronized frame is flushed", () => {
    const writes: Uint8Array[] = [];
    const scheduled: Array<() => void> = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: () => {},
    });

    buffer.enqueue(concat(enter, bytes("frame"), exit), () => {});
    scheduled[0]();
    buffer.enqueue(bytes("prompt> "), () => {});

    expect(writes).toEqual([concat(enter, bytes("frame"), exit), bytes("prompt> ")]);
  });

  test("flushes pending output before a terminal error is written", () => {
    const writes: Uint8Array[] = [];
    const scheduled: Array<() => void> = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
      scheduleFlush: (callback) => {
        scheduled.push(callback);
        return callback;
      },
      cancelFlush: () => {},
    });

    buffer.enqueue(concat(enter, bytes("frame"), exit), () => {});
    const writeTerminalError = () => {
      buffer.flush();
      writes.push(bytes("error"));
    };

    writeTerminalError();

    expect(writes).toEqual([concat(enter, bytes("frame"), exit), bytes("error")]);
    expect(scheduled).toHaveLength(1);
  });
  test("flushes pending output when disposed", () => {
    const writes: Uint8Array[] = [];
    const buffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        writes.push(data);
        onComplete();
      },
    });

    buffer.enqueue(enter, () => {});
    buffer.enqueue(exit, () => {});
    buffer.dispose();

    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual(concat(enter, exit));
  });
});
