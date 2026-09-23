import { invoke } from "@/platform/tauri-core";
import type { IDisposable, Terminal as XtermTerminal } from "@xterm/xterm";
import { useCallback, useEffect, useRef } from "react";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import {
  isFrontendDiagnosticEnabled,
  submitFrontendLog,
} from "@/features/logging/frontend-log-runtime";
import type { TerminalInput, TerminalSize } from "../types/terminal.types";
import { TerminalOscStream } from "../utils/terminal-osc-stream";
import {
  snapshotTerminalLayout,
  snapshotTerminalViewport,
  TerminalProtocolDiagnostics,
  type TerminalResizeSource,
} from "../utils/terminal-protocol-diagnostics";
import {
  getTerminalOutputFlowAction,
  getTerminalSize,
  releaseTerminalEventChannel,
  subscribeToTerminalEvents,
  terminalSizesEqual,
} from "../utils/terminal-protocol";
import { TerminalOutputWriteBuffer } from "../utils/terminal-output-write-buffer";
import {
  useTerminalWriteBuffer,
  type TerminalWriteBufferTraceEvent,
} from "./use-terminal-write-buffer";

interface UseTerminalConnectionOptions {
  connectionId?: string;
  getTerminalTheme: () => NonNullable<XtermTerminal["options"]["theme"]>;
  initialCommand?: string;
  isInitialized: boolean;
  onTerminalExit?: (sessionId: string) => void;
  remoteConnectionId?: string;
  reuseExistingConnection?: boolean;
  sessionId: string;
  terminal: XtermTerminal | null;
  updateSession: (
    sessionId: string,
    updates: {
      currentDirectory?: string;
      selection?: string;
      title?: string;
    },
  ) => void;
}

export function useTerminalConnection({
  connectionId,
  getTerminalTheme,
  initialCommand,
  isInitialized,
  onTerminalExit,
  remoteConnectionId,
  reuseExistingConnection = false,
  sessionId,
  terminal,
  updateSession,
}: UseTerminalConnectionOptions) {
  const currentConnectionIdRef = useRef<string | null>(null);
  const initialCommandSentForConnectionRef = useRef<string | null>(null);
  const onTerminalExitRef = useRef(onTerminalExit);
  const lastExitInfoRef = useRef<{ exitCode?: number | null; signal?: string | null } | null>(null);
  const lastSizeRef = useRef<TerminalSize | null>(null);
  const queuedOutputBytesRef = useRef(0);
  const outputPausedRef = useRef(false);
  const outputDecoderRef = useRef(new TextDecoder());
  const oscStreamRef = useRef(new TerminalOscStream());
  const diagnosticsRef = useRef<TerminalProtocolDiagnostics | null>(null);
  const terminalInputEncoder = useRef(new TextEncoder());

  const writeInput = useCallback(
    async (activeConnectionId: string, input: TerminalInput) => {
      const bytes =
        input.kind === "text"
          ? terminalInputEncoder.current.encode(input.data).byteLength
          : input.data.length;
      diagnosticsRef.current?.recordTrace("input-ipc", "start", { bytes, kind: input.kind });
      try {
        await invoke(remoteConnectionId ? "remote_terminal_write" : "terminal_write", {
          id: activeConnectionId,
          input,
        });
        diagnosticsRef.current?.recordTrace("input-ipc", "complete", {
          bytes,
          kind: input.kind,
        });
      } catch (error) {
        diagnosticsRef.current?.recordTrace("input-ipc", "failure", {
          bytes,
          kind: input.kind,
        });
        throw error;
      }
    },
    [remoteConnectionId],
  );

  const {
    write,
    writeBinary: enqueueBinary,
    flush,
  } = useTerminalWriteBuffer({
    getConnectionId: () => currentConnectionIdRef.current,
    onTrace: (event: TerminalWriteBufferTraceEvent) => {
      const { stage, ...fields } = event;
      diagnosticsRef.current?.recordTrace("input-buffer", stage, fields);
    },
    writeChunk: async (activeConnectionId, input) => {
      await writeInput(activeConnectionId, input);
    },
  });

  const writeBinary = useCallback(
    (data: string) => {
      const activeConnectionId = currentConnectionIdRef.current;
      if (!activeConnectionId || !data) return;
      const bytes = Array.from(data, (character) => character.charCodeAt(0) & 0xff);
      enqueueBinary(bytes);
    },
    [enqueueBinary],
  );

  const setOutputPaused = useCallback(
    (paused: boolean) => {
      const activeConnectionId = currentConnectionIdRef.current;
      if (!activeConnectionId || outputPausedRef.current === paused) return;

      outputPausedRef.current = paused;
      void invoke(remoteConnectionId ? "remote_terminal_set_paused" : "terminal_set_paused", {
        id: activeConnectionId,
        paused,
      }).catch(() => {
        outputPausedRef.current = !paused;
      });
    },
    [remoteConnectionId],
  );

  const sendTerminalSize = useCallback(
    (activeTerminal: XtermTerminal, source: TerminalResizeSource = "direct") => {
      const activeConnectionId = currentConnectionIdRef.current;
      if (!activeConnectionId) {
        diagnosticsRef.current?.recordTrace("resize", "skip-no-connection");
        return;
      }

      const size = getTerminalSize(activeTerminal);
      if (terminalSizesEqual(lastSizeRef.current, size)) {
        diagnosticsRef.current?.recordTrace("resize", "skip-equal", {
          cols: size.cols,
          rows: size.rows,
          source,
        });
        return;
      }
      lastSizeRef.current = size;
      diagnosticsRef.current?.recordPtyResize(source, size.cols, size.rows);
      diagnosticsRef.current?.recordTrace("resize", "ipc-start", {
        cols: size.cols,
        rows: size.rows,
        source,
      });

      void invoke(remoteConnectionId ? "remote_terminal_resize" : "terminal_resize", {
        id: activeConnectionId,
        size,
      })
        .then(() => {
          diagnosticsRef.current?.recordTrace("resize", "ipc-complete", {
            cols: size.cols,
            rows: size.rows,
            source,
          });
        })
        .catch(() => {
          diagnosticsRef.current?.recordTrace("resize", "ipc-failure", {
            cols: size.cols,
            rows: size.rows,
            source,
          });
          lastSizeRef.current = null;
        });
    },
    [remoteConnectionId],
  );

  useEffect(() => {
    onTerminalExitRef.current = onTerminalExit;
  }, [onTerminalExit]);

  useEffect(() => {
    currentConnectionIdRef.current = connectionId ?? null;
    lastExitInfoRef.current = null;
    lastSizeRef.current = null;
    queuedOutputBytesRef.current = 0;
    outputPausedRef.current = false;
    outputDecoderRef.current = new TextDecoder();
    oscStreamRef.current.reset();
    if (connectionId) updateSession(sessionId, { title: "" });
    void flush();
  }, [connectionId, flush, sessionId, updateSession]);

  useEffect(() => {
    if (!terminal || !isInitialized || !connectionId) return;

    const disposables: IDisposable[] = [];
    const inputEncoder = new TextEncoder();
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => {
        void submitFrontendLog({
          level: "debug",
          scope: "terminal.protocol",
          message: "terminal protocol activity",
          payload: { sessionId, ...payload },
        });
      },
      isEnabled: isFrontendDiagnosticEnabled,
    });
    diagnosticsRef.current = diagnostics;
    diagnostics.recordTrace("effect", "setup", {
      hasRemoteConnection: remoteConnectionId ? 1 : 0,
    });

    const getDiagnosticContainer = () => terminal.element ?? null;
    const layoutContainer = getDiagnosticContainer();
    const layoutViewport = layoutContainer?.querySelector<HTMLElement>(".xterm-viewport");
    const layoutObserver =
      layoutContainer && typeof ResizeObserver !== "undefined"
        ? new ResizeObserver(() => {
            if (!isFrontendDiagnosticEnabled()) return;
            diagnostics.recordResizeObserver();
            const container = getDiagnosticContainer();
            if (container) {
              diagnostics.recordLayout(snapshotTerminalLayout(terminal, container));
            }
          })
        : null;
    if (layoutObserver && layoutContainer) {
      layoutObserver.observe(layoutContainer);
      if (layoutViewport) layoutObserver.observe(layoutViewport);
      const screen = layoutContainer.querySelector<HTMLElement>(".xterm-screen");
      if (screen) layoutObserver.observe(screen);
      for (const canvas of layoutContainer.querySelectorAll("canvas")) {
        layoutObserver.observe(canvas);
      }
    }
    const diagnosticsHeartbeat = window.setInterval(() => {
      if (!isFrontendDiagnosticEnabled()) {
        diagnostics.recordHeartbeat(null);
        return;
      }
      const container = getDiagnosticContainer();
      diagnostics.recordHeartbeat(container ? snapshotTerminalLayout(terminal, container) : null);
    }, 1_000);

    const outputWriteBuffer = new TerminalOutputWriteBuffer({
      write: (data, onComplete) => {
        const viewportBeforeWrite = snapshotTerminalViewport(terminal);
        diagnostics.recordTrace("output", "xterm-write-start", {
          beforeBaseY: viewportBeforeWrite.baseY,
          beforeViewportY: viewportBeforeWrite.viewportY,
          bytes: data.byteLength,
        });
        terminal.write(data, () => {
          diagnostics.recordWriteComplete(viewportBeforeWrite, snapshotTerminalViewport(terminal));
          onComplete();
        });
      },
    });

    disposables.push(
      terminal.onData((data) => {
        diagnostics.recordInput(inputEncoder.encode(data).byteLength);
        write(data);
      }),
    );
    disposables.push(terminal.onBinary(writeBinary));
    disposables.push(
      terminal.onResize(() => {
        diagnostics.recordResize(terminal.cols, terminal.rows);
        sendTerminalSize(terminal, "xterm-resize");
      }),
    );
    disposables.push(
      terminal.onRender(({ start, end }) => {
        diagnostics.recordRender(start, end, terminal.rows);
        const viewport = snapshotTerminalViewport(terminal);
        diagnostics.recordTrace("render", "event", {
          baseY: viewport.baseY,
          cursorY: viewport.cursorY,
          end,
          start,
          viewportY: viewport.viewportY,
        });
      }),
    );
    disposables.push(terminal.onScroll((position) => diagnostics.recordScroll(position)));
    disposables.push(
      terminal.onSelectionChange(() => {
        const selection = terminal.getSelection();
        if (selection) updateSession(sessionId, { selection });
      }),
    );
    const unlistenThemeChange = themeRegistry.onThemeChange(() => {
      terminal.options.theme = getTerminalTheme();
    });

    const unsubscribeEvents = subscribeToTerminalEvents(connectionId, (event) => {
      if (event.event === "output") {
        const bytes = Uint8Array.from(event.data);
        diagnostics.recordOutput(bytes);
        queuedOutputBytesRef.current += bytes.byteLength;

        if (
          getTerminalOutputFlowAction(queuedOutputBytesRef.current, outputPausedRef.current) ===
          "pause"
        ) {
          setOutputPaused(true);
        }

        const decoded = outputDecoderRef.current.decode(bytes, { stream: true });
        const oscUpdates = oscStreamRef.current.feed(decoded);
        if (oscUpdates.title !== undefined || oscUpdates.currentDirectory !== undefined) {
          updateSession(sessionId, oscUpdates);
        }

        outputWriteBuffer.enqueue(bytes, () => {
          queuedOutputBytesRef.current = Math.max(
            0,
            queuedOutputBytesRef.current - bytes.byteLength,
          );
          if (
            getTerminalOutputFlowAction(queuedOutputBytesRef.current, outputPausedRef.current) ===
            "resume"
          ) {
            setOutputPaused(false);
          }
        });
        return;
      }

      if (event.event === "error") {
        outputWriteBuffer.flush();
        terminal.writeln(`\r\n\x1b[31mError: ${event.message}\x1b[0m`);
        return;
      }

      if (event.event === "exit") {
        lastExitInfoRef.current = event;
        return;
      }

      outputWriteBuffer.flush();
      void invoke(remoteConnectionId ? "close_remote_terminal" : "close_terminal", {
        id: connectionId,
      }).catch(() => {});
      releaseTerminalEventChannel(connectionId);

      const exitCode = lastExitInfoRef.current?.exitCode;
      const signal = lastExitInfoRef.current?.signal;
      if (exitCode === 0 && signal == null) {
        onTerminalExitRef.current?.(sessionId);
        return;
      }

      const details =
        signal != null
          ? `signal ${signal}`
          : exitCode != null
            ? `exit code ${exitCode}`
            : "unknown status";
      terminal.writeln(`\r\n\x1b[33mTerminal process exited unexpectedly (${details}).\x1b[0m`);
      terminal.writeln("\x1b[90mOpen a new terminal tab or close this one manually.\x1b[0m");
    });

    sendTerminalSize(terminal, "connection");

    return () => {
      diagnostics.recordTrace("effect", "cleanup");
      outputWriteBuffer.dispose();
      diagnostics.flush("dispose");
      window.clearInterval(diagnosticsHeartbeat);
      layoutObserver?.disconnect();
      if (diagnosticsRef.current === diagnostics) diagnosticsRef.current = null;
      void flush();
      if (outputPausedRef.current) setOutputPaused(false);
      for (const disposable of disposables) disposable.dispose();
      unlistenThemeChange();
      unsubscribeEvents();
    };
  }, [
    connectionId,
    flush,
    getTerminalTheme,
    isInitialized,
    remoteConnectionId,
    sendTerminalSize,
    sessionId,
    setOutputPaused,
    terminal,
    updateSession,
    write,
    writeBinary,
  ]);

  useEffect(() => {
    if (!initialCommand || !connectionId || reuseExistingConnection) return;
    if (initialCommandSentForConnectionRef.current === connectionId) return;

    initialCommandSentForConnectionRef.current = connectionId;
    const timeoutId = window.setTimeout(() => {
      write(`${initialCommand}\n`);
    }, 300);

    return () => window.clearTimeout(timeoutId);
  }, [connectionId, initialCommand, reuseExistingConnection, write]);

  return {
    currentConnectionIdRef,
    sendTerminalSize,
    writeBuffered: write,
  };
}
