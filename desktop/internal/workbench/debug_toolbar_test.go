package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// sentBreakpoints is one file's line breakpoints as a session was sent them.
type sentBreakpoints struct {
	path   string
	points []core.DebugSourceBreakpoint
}

// captureSetBreakpoints records each file's line breakpoints before Core sends them.
type captureSetBreakpoints struct {
	Kernel
	sent chan sentBreakpoints
}

func (k *captureSetBreakpoints) SetDebugBreakpoints(ctx context.Context, sessionID, sourcePath string, breakpoints []core.DebugSourceBreakpoint) (core.DebugUpdate, error) {
	select {
	case k.sent <- sentBreakpoints{path: sourcePath, points: breakpoints}:
	case <-ctx.Done():
		return core.DebugUpdate{}, ctx.Err()
	}
	return k.Kernel.SetDebugBreakpoints(ctx, sessionID, sourcePath, breakpoints)
}

// Mute keeps the breakpoints but sends every line as disabled; Unmute sends them as stored.
func TestDebugMuteKeepsTheBreakpointsAndSendsThemDisabled(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	source := d.frames[0].SourcePath
	d.breakpoints = map[string][]debugBreakpoint{source: {{line: 3}}}
	gate := &captureSetBreakpoints{Kernel: h.app.kernel, sent: make(chan sentBreakpoints, 1)}
	h.app.kernel = gate
	h.settle()

	h.clickNamed(h.shared("native.muteBreakpoints"))
	sent := awaitValueWithin(t, h, 10*time.Second, gate.sent, "the muted breakpoints")
	if !d.muted || sent.path != source || len(sent.points) != 1 || sent.points[0].Enabled {
		t.Fatalf("muted %v sent %+v, want line 3 disabled", d.muted, sent)
	}
	if lines := d.breakpoints[source]; len(lines) != 1 || lines[0].disabled {
		t.Fatalf("muting changed the stored breakpoints: %+v", lines)
	}

	h.settle()
	h.clickNamed(h.shared("desktop.debug.unmuteBreakpoints"))
	sent = awaitValueWithin(t, h, 10*time.Second, gate.sent, "the unmuted breakpoints")
	if d.muted || len(sent.points) != 1 || !sent.points[0].Enabled {
		t.Fatalf("muted %v sent %+v, want line 3 enabled", d.muted, sent)
	}
}

// Rerun stops the shown session and starts the debug again the way it was first started.
func TestDebugRerunStartsTheSameDebugAgain(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	first := p.debug.activeSession()
	h.clickNamed(h.shared("native.rerun"))
	awaitStateWithin(t, h, 30*time.Second, "the debug started again", func() bool {
		session := p.debug.activeSession()
		return session != nil && session != first && p.debug.state == "paused" && len(p.debug.sessions) == 1
	})
	if p.debug.rerun == nil {
		t.Fatal("the rerun session cannot be rerun")
	}
}

// The ⋮ menu switches the variables between the tree and JSON and collapses filtered frames.
func TestDebugMoreMenuSwitchesTheVariablesViewAndFilteredFrames(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	before := d.hideFiltered

	h.clickNamed(h.shared("native.moreActions"))
	h.click(center(h.popupHit(h.app.text.Debug.ViewJSON)))
	h.settle()
	if !d.vars.json || p.panels.debugMoreOpen {
		t.Fatalf("json %v, menu open %v after choosing JSON", d.vars.json, p.panels.debugMoreOpen)
	}

	h.clickNamed(h.shared("native.moreActions"))
	h.click(center(h.popupHit(h.shared("native.collapseFilteredFrames"))))
	h.settle()
	if d.hideFiltered == before {
		t.Fatal("the menu did not switch collapsing filtered frames")
	}

	h.clickNamed(h.shared("native.moreActions"))
	h.click(center(h.popupHit(h.app.text.Debug.ViewTree)))
	h.settle()
	if d.vars.json {
		t.Fatal("the menu did not switch back to the tree")
	}
}

// Before a session the adapter picker sits at the right end of the toolbar, not on a row of its
// own.
func TestDebugAdapterPickerSitsInTheToolbar(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	openDebugPanel(t, h, root)
	start := h.pageHit(h.app.text.Debug.Start).Bounds
	picker := h.pageHit(h.shared("desktop.debug.adapter")).Bounds
	if abs32(center(picker).Y-center(start).Y) > 2 || picker.X <= start.X {
		t.Fatalf("picker %+v is not on the toolbar row of Start %+v", picker, start)
	}
	if picker.Width > debugAdapterPickerWidth+1 {
		t.Fatalf("picker is %v wide, want at most %d", picker.Width, debugAdapterPickerWidth)
	}
}

func abs32(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}

// The disassembly tab keeps no buttons of its own: the toolbar's steps step one instruction
// while it shows, and the red dot in front of an instruction sets and removes its breakpoint.
func TestDebugDisassemblyStepsByInstructionAndTogglesItsGutterDot(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	d.section = debugSectionDisassembly
	h.app.invalidator.Invalidate()
	awaitStateWithin(t, h, 20*time.Second, "the instruction window", func() bool {
		return !d.disassembly.loading && len(d.disassembly.rows) > 0
	})
	h.settle()

	h.clickNamed(h.shared("debugger.disassembly.setBreakpoint"))
	awaitStateWithin(t, h, 10*time.Second, "the instruction breakpoint", func() bool {
		return len(d.instructionBreakpoints) == 1
	})
	h.settle()
	if _, ok := h.findPageHit(h.shared("debugger.disassembly.removeBreakpoint")); !ok {
		t.Fatal("the instruction with a breakpoint does not offer to remove it")
	}
	h.clickNamed(h.shared("debugger.disassembly.removeBreakpoint"))
	if len(d.instructionBreakpoints) != 0 {
		t.Fatalf("breakpoints = %+v, want none after the second click", d.instructionBreakpoints)
	}

	// The fixture refuses every granularity but the instruction one, so the step succeeding
	// proves the toolbar sent it.
	h.settle()
	h.clickNamed(h.app.text.Debug.StepInto)
	awaitStateWithin(t, h, 20*time.Second, "the instruction step", func() bool {
		return d.state == "paused" && strings.Contains(strings.Join(d.output, ""), "stepped instruction") && d.failure == ""
	})
	if d.failure != "" {
		t.Fatalf("the step failed: %s", d.failure)
	}
}

// The memory window reads at a typed address, aligns its rows and highlights that address's
// byte, lays the bytes out again by row width and base, and goes back to the instruction
// pointer keeping the layout chosen.
func TestDebugMemoryGoesToAnAddressAndChangesItsLayout(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	m := &p.debug.memory
	p.debug.section = debugSectionMemory
	h.app.invalidator.Invalidate()
	awaitStateWithin(t, h, 20*time.Second, "the memory at the instruction pointer", func() bool {
		return !m.loading && len(m.bytes) == 4 && m.input == "0x1000"
	})

	h.typeInto(h.shared("desktop.debug.memoryAddress"), func() { m.input = "" }, "8208")
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	// 8208 is 0x2010: the window starts on the 64-byte boundary before it.
	awaitStateWithin(t, h, 20*time.Second, "the memory at the typed address", func() bool {
		return !m.loading && m.address == "0x2000" && len(m.bytes) == debugMemoryBytes
	})
	if m.at != "0x2010" || m.input != "0x2010" || m.mark != 0x10 || m.bytes[m.mark] != 0x10 {
		t.Fatalf("at %q input %q mark %d, want 0x2010 highlighted", m.at, m.input, m.mark)
	}
	h.settle()
	if line := m.lines[1]; !strings.HasPrefix(line.text, "0x00002010") || line.text[line.cell[0]:line.cell[1]] != "10" {
		t.Fatalf("the second row %q marks %v, want the byte at 0x2010", line.text, line.cell)
	}

	h.clickNamed(h.shared("desktop.debug.memoryBytesPerRow"))
	h.click(center(h.popupHit(i18n.SharedFormat(h.app.language(), "desktop.debug.memoryRowBytes", map[string]string{"bytes": "32"}))))
	h.settle()
	if line := m.lines[0]; m.columns != 32 || len(m.lines) != debugMemoryBytes/32 || line.text[line.cell[0]:line.cell[1]] != "10" {
		t.Fatalf("columns %d, %d rows, first row marks %v", m.columns, len(m.lines), line.cell)
	}
	h.clickNamed(h.shared("desktop.debug.memoryRadix"))
	h.click(center(h.popupHit(h.shared("desktop.debug.memoryRadixBinary"))))
	h.settle()
	if line := m.lines[0]; m.radix != 2 || line.text[line.cell[0]:line.cell[1]] != "00010000" {
		t.Fatalf("radix %d marks %q, want the byte in binary", m.radix, line.text[line.cell[0]:line.cell[1]])
	}

	h.clickNamed(h.app.text.Debug.Reload)
	awaitStateWithin(t, h, 20*time.Second, "the memory back at the instruction pointer", func() bool {
		return !m.loading && m.address == "0x1000" && m.input == "0x1000" && len(m.bytes) == 4
	})
	if m.at != "" || m.mark != 0 || m.columns != 32 || m.radix != 2 {
		t.Fatalf("at %q mark %d layout %d/%d, want the instruction pointer in the kept layout", m.at, m.mark, m.columns, m.radix)
	}
}
