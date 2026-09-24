import { useCallback, useEffect, useRef } from "react";
import type { TerminalInput } from "../types/terminal.types";

interface TerminalWriteBufferOptions {
  getConnectionId: () => string | null;
  writeChunk: (connectionId: string, input: TerminalInput) => Promise<void>;
  onTrace?: (event: TerminalWriteBufferTraceEvent) => void;
}

export interface TerminalWriteBufferTraceEvent {
  kind?: TerminalInput["kind"];
  queueDepth: number;
  size?: number;
  stage:
    | "coalesce-text"
    | "enqueue-binary"
    | "enqueue-text"
    | "flush-complete"
    | "flush-dequeue"
    | "flush-failure"
    | "flush-join"
    | "flush-no-connection"
    | "flush-start"
    | "write-complete";
}

export function useTerminalWriteBuffer({
  getConnectionId,
  onTrace,
  writeChunk,
}: TerminalWriteBufferOptions) {
  const queueRef = useRef<TerminalInput[]>([]);
  const flushPromiseRef = useRef<Promise<void> | null>(null);
  const getConnectionIdRef = useRef(getConnectionId);
  const writeChunkRef = useRef(writeChunk);
  const onTraceRef = useRef(onTrace);

  getConnectionIdRef.current = getConnectionId;
  writeChunkRef.current = writeChunk;
  onTraceRef.current = onTrace;

  const trace = (event: TerminalWriteBufferTraceEvent) => {
    onTraceRef.current?.(event);
  };

  const flush = useCallback((): Promise<void> => {
    if (flushPromiseRef.current) {
      trace({ queueDepth: queueRef.current.length, stage: "flush-join" });
      return flushPromiseRef.current;
    }

    let shouldContinue = true;
    trace({ queueDepth: queueRef.current.length, stage: "flush-start" });
    const promise = (async () => {
      while (queueRef.current.length > 0) {
        const connectionId = getConnectionIdRef.current();
        if (!connectionId) {
          trace({ queueDepth: queueRef.current.length, stage: "flush-no-connection" });
          return;
        }

        const input = queueRef.current.shift();
        if (!input) continue;

        trace({
          kind: input.kind,
          queueDepth: queueRef.current.length,
          size: input.kind === "text" ? input.data.length : input.data.length,
          stage: "flush-dequeue",
        });

        try {
          await writeChunkRef.current(connectionId, input);
          trace({
            kind: input.kind,
            queueDepth: queueRef.current.length,
            size: input.kind === "text" ? input.data.length : input.data.length,
            stage: "write-complete",
          });
        } catch {
          queueRef.current.unshift(input);
          shouldContinue = false;
          trace({
            kind: input.kind,
            queueDepth: queueRef.current.length,
            size: input.kind === "text" ? input.data.length : input.data.length,
            stage: "flush-failure",
          });
          break;
        }
      }
    })().finally(() => {
      flushPromiseRef.current = null;
      trace({ queueDepth: queueRef.current.length, stage: "flush-complete" });
      if (shouldContinue && queueRef.current.length > 0 && getConnectionIdRef.current()) {
        void flush();
      }
    });

    flushPromiseRef.current = promise;
    return promise;
  }, []);

  const write = useCallback(
    (data: string) => {
      if (!data) return;
      const last = queueRef.current[queueRef.current.length - 1];
      if (last?.kind === "text") {
        last.data += data;
        trace({ queueDepth: queueRef.current.length, size: data.length, stage: "coalesce-text" });
      } else {
        queueRef.current.push({ kind: "text", data });
        trace({ queueDepth: queueRef.current.length, size: data.length, stage: "enqueue-text" });
      }
      void flush();
    },
    [flush],
  );

  const writeBinary = useCallback(
    (data: number[]) => {
      if (data.length === 0) return;
      queueRef.current.push({ kind: "binary", data });
      trace({
        kind: "binary",
        queueDepth: queueRef.current.length,
        size: data.length,
        stage: "enqueue-binary",
      });
      void flush();
    },
    [flush],
  );

  useEffect(() => {
    return () => {
      void flush();
    };
  }, [flush]);

  return { write, writeBinary, flush };
}
