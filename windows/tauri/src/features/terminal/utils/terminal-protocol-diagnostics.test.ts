import { describe, expect, test } from "bun:test";
import {
  TerminalProtocolDiagnostics,
  type TerminalLayoutSnapshot,
  type TerminalProtocolDiagnosticPayload,
  type TerminalViewportSnapshot,
} from "./terminal-protocol-diagnostics";

function viewport(baseY: number, viewportY: number): TerminalViewportSnapshot {
  return { baseY, bufferType: "normal", cursorY: 0, viewportY };
}

function layout(overrides: Partial<TerminalLayoutSnapshot> = {}): TerminalLayoutSnapshot {
  return {
    bufferBaseY: 0,
    bufferType: "normal",
    bufferViewportY: 0,
    canvasCssHeight: 600,
    canvasCssWidth: 985,
    canvasPixelHeight: 1_200,
    canvasPixelWidth: 1_970,
    canvasTop: 0,
    containerHeight: 600,
    containerWidth: 1_000,
    screenHeight: 600,
    screenTop: 0,
    screenWidth: 985,
    terminalCols: 120,
    terminalRows: 30,
    viewportClientHeight: 600,
    viewportClientWidth: 985,
    viewportOverflowY: "scroll",
    viewportScrollHeight: 600,
    viewportScrollTop: 0,
    ...overrides,
  };
}

describe("TerminalProtocolDiagnostics", () => {
  test("counts control sequences split across output chunks without retaining text", () => {
    let now = 0;
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      intervalMs: 1_000,
      isEnabled: () => true,
      now: () => now,
    });

    diagnostics.recordOutput(Uint8Array.from([0x1b, 0x5b, 0x33]));
    diagnostics.recordOutput(Uint8Array.from([0x4a, 0x1b, 0x5b, 0x48]));
    now = 1_000;
    diagnostics.recordInput(1);

    expect(emitted).toHaveLength(1);
    expect(emitted[0]).toMatchObject({
      csiSequences: 2,
      cursorHome: 1,
      eraseScrollback: 1,
      inputBytes: 1,
      outputBytes: 7,
      outputChunks: 2,
    });
    expect(Object.values(emitted[0]).join(" ")).not.toContain("J");
  });

  test("tracks erase commands inside and outside synchronized output", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordOutput(new TextEncoder().encode("\x1b[?2026h\x1b[2J"));
    diagnostics.recordOutput(new TextEncoder().encode("\x1b[3J\x1b[?2026l\x1b[2J"));
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      synchronizedEraseDisplay: 1,
      synchronizedEraseScrollback: 1,
      eraseDisplay: 2,
      eraseScrollback: 1,
    });
  });

  test("counts cursor redraw movement separately from viewport geometry", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    const encoder = new TextEncoder();
    diagnostics.recordOutput(encoder.encode("\x1b[37A\x1b[2K\x1b[1B\x1b[G\x1b[4;1H"));
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      cursorDownRows: 1,
      cursorDownSequences: 1,
      cursorLeftSequences: 1,
      cursorPositionSequences: 1,
      cursorUpRows: 37,
      cursorUpSequences: 1,
      eraseLineSequences: 1,
      classification: "no-suspected-instability",
    });
  });

  test("classifies repeated line erase and cursor-up redraws", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    const encoder = new TextEncoder();
    diagnostics.recordOutput(encoder.encode("\x1b[2K\x1b[1A".repeat(30)));
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      classification: "cursor-redraw-churn",
      cursorUpSequences: 30,
      eraseLineSequences: 30,
    });
  });

  test("reports viewport resets and bottom yanks after parsed writes", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordWriteComplete(viewport(100, 40), viewport(100, 100));
    diagnostics.recordWriteComplete(viewport(100, 40), viewport(0, 0));
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      viewportChanges: 2,
      viewportResetToTop: 1,
      viewportYankToBottom: 1,
      writeCallbacks: 2,
    });
  });

  test("classifies repeated geometry and PTY size oscillation as layout feedback", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordPtyResize("fit", 120, 30);
    diagnostics.recordPtyResize("xterm-resize", 119, 30);
    const stable = layout();
    const changed = layout({ containerWidth: 999, viewportClientWidth: 984, terminalCols: 119 });
    diagnostics.recordLayout(stable);
    diagnostics.recordLayout(changed);
    diagnostics.recordLayout(stable);
    diagnostics.recordLayout(changed);
    diagnostics.recordLayout(stable);
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      classification: "layout-pty-feedback",
      layoutChangeEvents: 4,
      layoutOscillations: 3,
      ptyResizeEvents: 2,
      ptyResizeFitEvents: 1,
      ptyResizeXtermEvents: 1,
    });
  });

  test("classifies viewport overflow and scrollbar width changes", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordLayout(layout());
    diagnostics.recordLayout(layout({ viewportOverflowY: "auto", viewportClientWidth: 1_000 }));
    diagnostics.recordLayout(layout());
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      classification: "scrollbar-layout-instability",
      viewportClientWidthChanges: 2,
      viewportOverflowChanges: 2,
    });
  });

  test("classifies internal canvas oscillation without a container resize", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordLayout(layout());
    diagnostics.recordLayout(layout({ canvasPixelWidth: 1_971 }));
    diagnostics.recordLayout(layout());
    diagnostics.flush("test");

    expect(emitted[0]).toMatchObject({
      canvasGeometryChanges: 2,
      classification: "render-surface-instability",
      layoutChangeEvents: 0,
    });
  });

  test("keeps an ordered bounded trace without recording input text", () => {
    const emitted: TerminalProtocolDiagnosticPayload[] = [];
    const diagnostics = new TerminalProtocolDiagnostics({
      emit: (payload) => emitted.push(payload),
      isEnabled: () => true,
      now: () => 0,
    });

    diagnostics.recordTrace("effect", "setup");
    diagnostics.recordInput(1);
    diagnostics.recordTrace("input-ipc", "start", { bytes: 1, kind: "text" });
    diagnostics.recordTrace("input-ipc", "complete", { bytes: 1, kind: "text" });
    for (let index = 0; index < 52; index += 1) {
      diagnostics.recordTrace("render", "event", { index });
    }
    diagnostics.flush("test");

    const traceTail = String(emitted[0]?.traceTail ?? "").split("|");
    expect(traceTail).toHaveLength(48);
    expect(traceTail[0]).toContain("render:event,index=4");
    expect(traceTail[traceTail.length - 1]).toContain("render:event,index=51");
    expect(emitted[0]?.traceTail).not.toContain("secret");
    expect(emitted[0]).toMatchObject({ traceEvents: 56 });
  });
});
