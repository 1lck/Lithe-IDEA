import type { Terminal as XtermTerminal } from "@xterm/xterm";

export interface TerminalViewportSnapshot {
  baseY: number;
  bufferType: "normal" | "alternate";
  cursorY: number;
  viewportY: number;
}

export type TerminalResizeSource = "connection" | "fit" | "xterm-resize" | "direct";

export interface TerminalLayoutSnapshot {
  bufferBaseY: number;
  bufferType: "normal" | "alternate";
  bufferViewportY: number;
  canvasCssHeight: number;
  canvasCssWidth: number;
  canvasPixelHeight: number;
  canvasPixelWidth: number;
  canvasTop: number;
  containerHeight: number;
  containerWidth: number;
  screenHeight: number;
  screenTop: number;
  screenWidth: number;
  terminalCols: number;
  terminalRows: number;
  viewportClientHeight: number;
  viewportClientWidth: number;
  viewportOverflowY: string;
  viewportScrollHeight: number;
  viewportScrollTop: number;
}

export type TerminalProtocolDiagnosticPayload = Record<string, number | string>;

export type TerminalDiagnosticTraceFields = Record<string, number | string>;

interface TerminalProtocolDiagnosticsOptions {
  emit: (payload: TerminalProtocolDiagnosticPayload) => void;
  intervalMs?: number;
  isEnabled: () => boolean;
  now?: () => number;
}

const CONTROL_PATTERNS = {
  alternateEnter: "\x1b[?1049h",
  alternateExit: "\x1b[?1049l",
  cursorHome: "\x1b[H",
  eraseDisplay: "\x1b[2J",
  eraseScrollback: "\x1b[3J",
  synchronizedEnter: "\x1b[?2026h",
  synchronizedExit: "\x1b[?2026l",
} as const;

const CSI_SEQUENCE = new RegExp(`${String.fromCharCode(0x1b)}\\[[0-?]*[ -/]*[@-~]`, "g");
const CONTROL_CARRY_LENGTH = 16;

function getCsiMovementRows(sequence: string): number {
  const parameterText = sequence.slice(2, -1).replace(/^[?>]/, "");
  const firstParameter = Number.parseInt(parameterText.split(";")[0] ?? "", 10);
  return Number.isSafeInteger(firstParameter) && firstParameter > 0 ? firstParameter : 1;
}

function emptyCounters() {
  return {
    alternateEnter: 0,
    alternateExit: 0,
    canvasGeometryChanges: 0,
    csiSequences: 0,
    cursorDownSequences: 0,
    cursorDownRows: 0,
    cursorHome: 0,
    cursorLeftSequences: 0,
    cursorPositionSequences: 0,
    cursorUpSequences: 0,
    cursorUpRows: 0,
    eraseLineSequences: 0,
    eraseDisplay: 0,
    eraseScrollback: 0,
    fullRenderEvents: 0,
    heartbeatSamples: 0,
    inputBytes: 0,
    inputEvents: 0,
    layoutChangeEvents: 0,
    layoutOscillations: 0,
    layoutSamples: 0,
    outputBytes: 0,
    outputChunks: 0,
    ptyResizeConnectionEvents: 0,
    ptyResizeDirectEvents: 0,
    ptyResizeEvents: 0,
    ptyResizeFitEvents: 0,
    ptyResizeXtermEvents: 0,
    renderEvents: 0,
    renderedRows: 0,
    resizeEvents: 0,
    resizeObserverEvents: 0,
    screenGeometryChanges: 0,
    scrollEvents: 0,
    synchronizedFrameWrites: 0,
    synchronizedEraseDisplay: 0,
    synchronizedEraseScrollback: 0,
    synchronizedEraseSuppressed: 0,
    synchronizedEnter: 0,
    synchronizedExit: 0,
    traceEvents: 0,
    terminalColumnChanges: 0,
    terminalRowChanges: 0,
    viewportClientWidthChanges: 0,
    viewportOverflowChanges: 0,
    viewportScrollHeightChanges: 0,
    viewportChanges: 0,
    viewportResetToTop: 0,
    viewportYankToBottom: 0,
    writeCallbacks: 0,
  };
}

type Counters = ReturnType<typeof emptyCounters>;

export function snapshotTerminalViewport(terminal: XtermTerminal): TerminalViewportSnapshot {
  const active = terminal.buffer.active;
  return {
    baseY: active.baseY,
    bufferType: terminal.buffer.active === terminal.buffer.alternate ? "alternate" : "normal",
    cursorY: active.cursorY,
    viewportY: active.viewportY,
  };
}

function roundLayoutValue(value: number): number {
  return Math.round(value * 100) / 100;
}

export function snapshotTerminalLayout(
  terminal: XtermTerminal,
  container: HTMLElement,
): TerminalLayoutSnapshot {
  const viewport = container.querySelector<HTMLElement>(".xterm-viewport");
  const screen = container.querySelector<HTMLElement>(".xterm-screen");
  const canvas = screen?.querySelector<HTMLCanvasElement>("canvas");
  const containerRect = container.getBoundingClientRect();
  const screenRect = screen?.getBoundingClientRect();
  const canvasRect = canvas?.getBoundingClientRect();
  const active = terminal.buffer.active;
  const computedOverflow =
    viewport && typeof window !== "undefined"
      ? window.getComputedStyle(viewport).overflowY
      : "missing";

  return {
    bufferBaseY: active.baseY,
    bufferType: terminal.buffer.active === terminal.buffer.alternate ? "alternate" : "normal",
    bufferViewportY: active.viewportY,
    canvasCssHeight: roundLayoutValue(canvasRect?.height ?? 0),
    canvasCssWidth: roundLayoutValue(canvasRect?.width ?? 0),
    canvasPixelHeight: canvas?.height ?? 0,
    canvasPixelWidth: canvas?.width ?? 0,
    canvasTop: roundLayoutValue((canvasRect?.top ?? 0) - containerRect.top),
    containerHeight: roundLayoutValue(containerRect.height),
    containerWidth: roundLayoutValue(containerRect.width),
    screenHeight: roundLayoutValue(screenRect?.height ?? 0),
    screenTop: roundLayoutValue((screenRect?.top ?? 0) - containerRect.top),
    screenWidth: roundLayoutValue(screenRect?.width ?? 0),
    terminalCols: terminal.cols,
    terminalRows: terminal.rows,
    viewportClientHeight: viewport?.clientHeight ?? 0,
    viewportClientWidth: viewport?.clientWidth ?? 0,
    viewportOverflowY: computedOverflow,
    viewportScrollHeight: viewport?.scrollHeight ?? 0,
    viewportScrollTop: roundLayoutValue(viewport?.scrollTop ?? 0),
  };
}

export class TerminalProtocolDiagnostics {
  private readonly emit: TerminalProtocolDiagnosticsOptions["emit"];
  private readonly intervalMs: number;
  private readonly isEnabled: TerminalProtocolDiagnosticsOptions["isEnabled"];
  private readonly now: () => number;
  private active = false;
  private carry = "";
  private counters: Counters = emptyCounters();
  private intervalStartedAt: number;
  private maxOutputChunkBytes = 0;
  private minOutputChunkBytes = Number.POSITIVE_INFINITY;
  private scrollMaximum = 0;
  private scrollMinimum = Number.POSITIVE_INFINITY;
  private lastLayout: TerminalLayoutSnapshot | null = null;
  private layoutSignatures: string[] = [];
  private diagnosticSynchronizedOutput = false;
  private traceSequence = 0;
  private traceTail: string[] = [];

  constructor(options: TerminalProtocolDiagnosticsOptions) {
    this.emit = options.emit;
    this.intervalMs = options.intervalMs ?? 1_000;
    this.isEnabled = options.isEnabled;
    this.now = options.now ?? performance.now.bind(performance);
    this.intervalStartedAt = this.now();
  }

  recordOutput(bytes: Uint8Array): void {
    if (!this.prepare()) return;
    this.counters.outputChunks += 1;
    this.counters.outputBytes += bytes.byteLength;
    this.appendTrace("output", "event", { bytes: bytes.byteLength });
    this.minOutputChunkBytes = Math.min(this.minOutputChunkBytes, bytes.byteLength);
    this.maxOutputChunkBytes = Math.max(this.maxOutputChunkBytes, bytes.byteLength);

    let chunk = "";
    for (const byte of bytes) chunk += String.fromCharCode(byte);
    const candidate = this.carry + chunk;
    const carryLength = this.carry.length;

    for (const [counter, pattern] of Object.entries(CONTROL_PATTERNS) as Array<
      [keyof Pick<Counters, keyof typeof CONTROL_PATTERNS>, string]
    >) {
      let offset = candidate.indexOf(pattern);
      while (offset >= 0) {
        if (offset + pattern.length > carryLength) this.counters[counter] += 1;
        offset = candidate.indexOf(pattern, offset + 1);
      }
    }

    CSI_SEQUENCE.lastIndex = 0;
    for (let match = CSI_SEQUENCE.exec(candidate); match; match = CSI_SEQUENCE.exec(candidate)) {
      if (match.index + match[0].length <= carryLength) continue;

      this.counters.csiSequences += 1;
      const sequence = match[0];

      if (sequence === CONTROL_PATTERNS.synchronizedEnter) {
        this.diagnosticSynchronizedOutput = true;
      }
      if (sequence === CONTROL_PATTERNS.synchronizedExit) {
        this.diagnosticSynchronizedOutput = false;
      }
      const eraseParameter = getEraseParameter(sequence);
      if (eraseParameter === 2) {
        if (this.diagnosticSynchronizedOutput) this.counters.synchronizedEraseDisplay += 1;
      }
      if (eraseParameter === 3) {
        if (this.diagnosticSynchronizedOutput) this.counters.synchronizedEraseScrollback += 1;
      }

      switch (sequence.charAt(sequence.length - 1)) {
        case "A":
          this.counters.cursorUpSequences += 1;
          this.counters.cursorUpRows += getCsiMovementRows(sequence);
          break;
        case "B":
          this.counters.cursorDownSequences += 1;
          this.counters.cursorDownRows += getCsiMovementRows(sequence);
          break;
        case "G":
          this.counters.cursorLeftSequences += 1;
          break;
        case "H":
          this.counters.cursorPositionSequences += 1;
          break;
        case "K":
          this.counters.eraseLineSequences += 1;
          break;
      }
    }
    this.carry = candidate.slice(-CONTROL_CARRY_LENGTH);
    this.flushIfDue();
  }

  recordInput(byteLength: number): void {
    if (!this.prepare()) return;
    this.counters.inputEvents += 1;
    this.counters.inputBytes += byteLength;
    this.appendTrace("input", "on-data", { bytes: byteLength });
    this.flushIfDue();
  }

  recordHeartbeat(layout: TerminalLayoutSnapshot | null): void {
    if (!this.prepare()) return;
    this.counters.heartbeatSamples += 1;
    if (layout) this.recordLayout(layout);
    this.flushIfDue();
  }

  recordRender(start: number, end: number, rows: number): void {
    if (!this.prepare()) return;
    this.counters.renderEvents += 1;
    this.counters.renderedRows += Math.max(0, end - start + 1);
    if (start === 0 && end >= rows - 1) this.counters.fullRenderEvents += 1;
    this.flushIfDue();
  }

  recordResize(cols?: number, rows?: number): void {
    if (!this.prepare()) return;
    this.counters.resizeEvents += 1;
    this.appendTrace("resize", "xterm-event", {
      ...(cols === undefined ? {} : { cols }),
      ...(rows === undefined ? {} : { rows }),
    });
    this.flushIfDue();
  }

  recordResizeObserver(): void {
    if (!this.prepare()) return;
    this.counters.resizeObserverEvents += 1;
    this.appendTrace("resize", "observer");
    this.flushIfDue();
  }

  recordPtyResize(source: TerminalResizeSource, cols: number, rows: number): void {
    if (!this.prepare()) return;
    this.counters.ptyResizeEvents += 1;
    if (source === "connection") this.counters.ptyResizeConnectionEvents += 1;
    if (source === "direct") this.counters.ptyResizeDirectEvents += 1;
    if (source === "fit") this.counters.ptyResizeFitEvents += 1;
    if (source === "xterm-resize") this.counters.ptyResizeXtermEvents += 1;
    this.lastResizeCols = cols;
    this.lastResizeRows = rows;
    this.appendTrace("resize", `pty-${source}`, { cols, rows });
    this.flushIfDue();
  }

  recordLayout(layout: TerminalLayoutSnapshot): void {
    if (!this.prepare()) return;
    this.counters.layoutSamples += 1;

    const previous = this.lastLayout;
    if (previous) {
      const changed =
        previous.containerWidth !== layout.containerWidth ||
        previous.containerHeight !== layout.containerHeight ||
        previous.viewportClientWidth !== layout.viewportClientWidth ||
        previous.viewportClientHeight !== layout.viewportClientHeight ||
        previous.viewportScrollHeight !== layout.viewportScrollHeight ||
        previous.viewportOverflowY !== layout.viewportOverflowY ||
        previous.terminalCols !== layout.terminalCols ||
        previous.terminalRows !== layout.terminalRows;
      if (changed) this.counters.layoutChangeEvents += 1;
      if (previous.terminalCols !== layout.terminalCols) {
        this.counters.terminalColumnChanges += 1;
      }
      if (previous.terminalRows !== layout.terminalRows) {
        this.counters.terminalRowChanges += 1;
      }
      if (previous.viewportClientWidth !== layout.viewportClientWidth) {
        this.counters.viewportClientWidthChanges += 1;
      }
      if (previous.viewportOverflowY !== layout.viewportOverflowY) {
        this.counters.viewportOverflowChanges += 1;
      }
      if (previous.viewportScrollHeight !== layout.viewportScrollHeight) {
        this.counters.viewportScrollHeightChanges += 1;
      }
      if (
        previous.canvasCssWidth !== layout.canvasCssWidth ||
        previous.canvasCssHeight !== layout.canvasCssHeight ||
        previous.canvasPixelWidth !== layout.canvasPixelWidth ||
        previous.canvasPixelHeight !== layout.canvasPixelHeight ||
        previous.canvasTop !== layout.canvasTop
      ) {
        this.counters.canvasGeometryChanges += 1;
      }
      if (
        previous.screenWidth !== layout.screenWidth ||
        previous.screenHeight !== layout.screenHeight ||
        previous.screenTop !== layout.screenTop
      ) {
        this.counters.screenGeometryChanges += 1;
      }
    }

    const signature = [
      layout.containerWidth,
      layout.containerHeight,
      layout.viewportClientWidth,
      layout.viewportClientHeight,
      layout.viewportScrollHeight,
      layout.viewportOverflowY,
      layout.terminalCols,
      layout.terminalRows,
      layout.screenWidth,
      layout.screenHeight,
      layout.screenTop,
      layout.canvasCssWidth,
      layout.canvasCssHeight,
      layout.canvasPixelWidth,
      layout.canvasPixelHeight,
      layout.canvasTop,
    ].join(":");
    const previousSignature = this.layoutSignatures[this.layoutSignatures.length - 1];
    const twoBackSignature = this.layoutSignatures[this.layoutSignatures.length - 2];
    if (twoBackSignature === signature && previousSignature !== signature) {
      this.counters.layoutOscillations += 1;
    }
    this.layoutSignatures.push(signature);
    if (this.layoutSignatures.length > 4) this.layoutSignatures.shift();
    this.lastLayout = layout;
    this.flushIfDue();
  }

  recordScroll(position: number): void {
    if (!this.prepare()) return;
    this.counters.scrollEvents += 1;
    this.scrollMinimum = Math.min(this.scrollMinimum, position);
    this.scrollMaximum = Math.max(this.scrollMaximum, position);
    this.appendTrace("scroll", "event", { position });
    this.flushIfDue();
  }

  recordSynchronizedEraseSuppressed(): void {
    if (!this.prepare()) return;
    this.counters.synchronizedEraseSuppressed += 1;
    this.flushIfDue();
  }

  recordSynchronizedFrameWrite(): void {
    if (!this.prepare()) return;
    this.counters.synchronizedFrameWrites += 1;
    this.flushIfDue();
  }

  recordWriteComplete(before: TerminalViewportSnapshot, after: TerminalViewportSnapshot): void {
    if (!this.prepare()) return;
    this.counters.writeCallbacks += 1;
    if (before.viewportY !== after.viewportY) this.counters.viewportChanges += 1;
    if (before.viewportY > 0 && after.viewportY === 0) this.counters.viewportResetToTop += 1;
    if (before.viewportY < before.baseY && after.baseY > 0 && after.viewportY === after.baseY) {
      this.counters.viewportYankToBottom += 1;
    }
    this.appendTrace("output", "write-complete", {
      afterBaseY: after.baseY,
      afterViewportY: after.viewportY,
      beforeBaseY: before.baseY,
      beforeViewportY: before.viewportY,
    });
    this.flushIfDue();
  }

  recordTrace(category: string, stage: string, fields: TerminalDiagnosticTraceFields = {}): void {
    if (!this.prepare()) return;
    this.appendTrace(category, stage, fields);
    this.flushIfDue();
  }

  flush(reason = "interval"): void {
    if (!this.isEnabled() || !this.hasEvents()) return;
    const now = this.now();
    this.emit({
      ...this.counters,
      durationMs: Math.max(0, Math.round(now - this.intervalStartedAt)),
      maxOutputChunkBytes: this.maxOutputChunkBytes,
      minOutputChunkBytes: Number.isFinite(this.minOutputChunkBytes) ? this.minOutputChunkBytes : 0,
      reason,
      traceTail: this.traceTail.join("|"),
      scrollMaximum: this.scrollMaximum,
      scrollMinimum: Number.isFinite(this.scrollMinimum) ? this.scrollMinimum : 0,
      classification: this.classify(),
      lastContainerWidth: this.lastLayout?.containerWidth ?? 0,
      lastContainerHeight: this.lastLayout?.containerHeight ?? 0,
      lastCanvasCssHeight: this.lastLayout?.canvasCssHeight ?? 0,
      lastCanvasCssWidth: this.lastLayout?.canvasCssWidth ?? 0,
      lastCanvasPixelHeight: this.lastLayout?.canvasPixelHeight ?? 0,
      lastCanvasPixelWidth: this.lastLayout?.canvasPixelWidth ?? 0,
      lastCanvasTop: this.lastLayout?.canvasTop ?? 0,
      lastScreenHeight: this.lastLayout?.screenHeight ?? 0,
      lastScreenTop: this.lastLayout?.screenTop ?? 0,
      lastScreenWidth: this.lastLayout?.screenWidth ?? 0,
      lastViewportClientWidth: this.lastLayout?.viewportClientWidth ?? 0,
      lastViewportScrollHeight: this.lastLayout?.viewportScrollHeight ?? 0,
      lastViewportScrollTop: this.lastLayout?.viewportScrollTop ?? 0,
      lastViewportOverflowY: this.lastLayout?.viewportOverflowY ?? "unknown",
      lastTerminalCols: this.lastLayout?.terminalCols ?? this.lastResizeCols,
      lastTerminalRows: this.lastLayout?.terminalRows ?? this.lastResizeRows,
    });
    this.reset(now);
  }

  private flushIfDue(): void {
    if (this.now() - this.intervalStartedAt >= this.intervalMs) this.flush();
  }

  private hasEvents(): boolean {
    return Object.values(this.counters).some((value) => value > 0);
  }

  private prepare(): boolean {
    if (this.isEnabled()) {
      if (!this.active) {
        this.active = true;
        this.reset(this.now());
      }
      return true;
    }
    if (this.active) {
      this.active = false;
      this.reset(this.now());
    }
    return false;
  }

  private reset(now: number): void {
    this.counters = emptyCounters();
    this.intervalStartedAt = now;
    this.maxOutputChunkBytes = 0;
    this.minOutputChunkBytes = Number.POSITIVE_INFINITY;
    this.scrollMaximum = 0;
    this.scrollMinimum = Number.POSITIVE_INFINITY;
    this.lastLayout = null;
    this.layoutSignatures = [];
    this.traceTail = [];
    this.lastResizeCols = 0;
    this.lastResizeRows = 0;
  }

  private lastResizeCols = 0;
  private lastResizeRows = 0;

  private appendTrace(
    category: string,
    stage: string,
    fields: TerminalDiagnosticTraceFields = {},
  ): void {
    this.traceSequence += 1;
    const suffix = Object.entries(fields)
      .map(([key, value]) => `${key}=${value}`)
      .join(",");
    const entry = `${this.traceSequence}@${Math.round(this.now())}:${category}:${stage}${suffix ? `,${suffix}` : ""}`;
    this.traceTail.push(entry);
    if (this.traceTail.length > 48) this.traceTail.shift();
    this.counters.traceEvents += 1;
  }

  private classify(): string {
    if (this.counters.canvasGeometryChanges >= 2 || this.counters.screenGeometryChanges >= 2) {
      return "render-surface-instability";
    }
    if (this.counters.layoutOscillations >= 2 && this.counters.ptyResizeEvents >= 2) {
      return "layout-pty-feedback";
    }
    if (
      this.counters.viewportOverflowChanges >= 2 ||
      this.counters.viewportClientWidthChanges >= 2
    ) {
      return "scrollbar-layout-instability";
    }
    if (this.counters.viewportResetToTop > 0 || this.counters.viewportYankToBottom > 0) {
      return this.counters.eraseDisplay > 0 || this.counters.eraseScrollback > 0
        ? "control-sequence-viewport-reset"
        : "viewport-reset";
    }
    if (this.counters.cursorUpSequences >= 30 && this.counters.eraseLineSequences >= 30) {
      return "cursor-redraw-churn";
    }
    if (this.counters.fullRenderEvents >= 30 || this.counters.renderEvents >= 120) {
      return "high-render-frequency";
    }
    if (
      this.counters.scrollEvents >= 8 &&
      this.counters.inputEvents + this.counters.outputChunks > 0
    ) {
      return "interactive-scroll-churn";
    }
    return "no-suspected-instability";
  }
}

function getEraseParameter(sequence: string): 2 | 3 | undefined {
  if (sequence.charAt(sequence.length - 1) !== "J") return undefined;
  const parameterText = sequence.slice(2, -1).replace(/^[?>]/, "");
  if (parameterText === "2") return 2;
  if (parameterText === "3") return 3;
  return undefined;
}
