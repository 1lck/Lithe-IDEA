package workbench

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// debugCall is one breakpoint call the host made for a session and the DAP requests Core wrote
// for it.
type debugCall struct {
	session  string
	kind     string // "muted", "unmuted" or "breakpoints"
	requests []dapRequest
}

// dapRequest is one DAP request as Core framed it for the adapter.
type dapRequest struct {
	command   string
	arguments map[string]any
}

// request is the first request of the call named command, or nil.
func (c debugCall) request(command string) *dapRequest {
	for index := range c.requests {
		if c.requests[index].command == command {
			return &c.requests[index]
		}
	}
	return nil
}

// captureBreakpointCalls records each mute and source breakpoint call with what Core sent.
type captureBreakpointCalls struct {
	Kernel
	calls chan debugCall
}

func (k *captureBreakpointCalls) record(ctx context.Context, call debugCall, update core.DebugUpdate, err error) (core.DebugUpdate, error) {
	if err != nil {
		return update, err
	}
	for _, frame := range update.OutboundFrames {
		data, decodeErr := base64.StdEncoding.DecodeString(frame)
		if decodeErr != nil {
			return core.DebugUpdate{}, decodeErr
		}
		_, body, _ := strings.Cut(string(data), "\r\n\r\n")
		var message struct {
			Type      string         `json:"type"`
			Command   string         `json:"command"`
			Arguments map[string]any `json:"arguments"`
		}
		if json.Unmarshal([]byte(body), &message) == nil && message.Type == "request" {
			call.requests = append(call.requests, dapRequest{command: message.Command, arguments: message.Arguments})
		}
	}
	select {
	case k.calls <- call:
	case <-ctx.Done():
		return core.DebugUpdate{}, ctx.Err()
	}
	return update, nil
}

func (k *captureBreakpointCalls) SetDebugBreakpointsMuted(ctx context.Context, sessionID string, muted bool) (core.DebugUpdate, error) {
	update, err := k.Kernel.SetDebugBreakpointsMuted(ctx, sessionID, muted)
	kind := "unmuted"
	if muted {
		kind = "muted"
	}
	return k.record(ctx, debugCall{session: sessionID, kind: kind}, update, err)
}

func (k *captureBreakpointCalls) SetDebugBreakpoints(ctx context.Context, sessionID, sourcePath string, breakpoints []core.DebugSourceBreakpoint) (core.DebugUpdate, error) {
	update, err := k.Kernel.SetDebugBreakpoints(ctx, sessionID, sourcePath, breakpoints)
	return k.record(ctx, debugCall{session: sessionID, kind: "breakpoints"}, update, err)
}

// sentLines is the lines of a setBreakpoints request.
func sentLines(request *dapRequest) []float64 {
	var lines []float64
	points, _ := request.arguments["breakpoints"].([]any)
	for _, point := range points {
		if entry, ok := point.(map[string]any); ok {
			line, _ := entry["line"].(float64)
			lines = append(lines, line)
		}
	}
	return lines
}

// sentFilters is the filters of a setExceptionBreakpoints request.
func sentFilters(request *dapRequest) []any {
	filters, _ := request.arguments["filters"].([]any)
	return filters
}

// Mute keeps the breakpoints but has Core send every kind empty, the adapter's default exception
// filter included; Unmute has Core send them as stored.
func TestDebugMuteSendsEveryKindEmptyAndUnmuteRestoresThem(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	source := d.frames[0].SourcePath
	gate := &captureBreakpointCalls{Kernel: h.app.kernel, calls: make(chan debugCall, 4)}
	h.app.kernel = gate
	d.breakpoints = map[string][]debugBreakpoint{source: {{line: 3}}}
	h.app.sendDebugBreakpoints(p, source)
	stored := awaitValueWithin(t, h, 10*time.Second, gate.calls, "the stored breakpoint")
	if request := stored.request("setBreakpoints"); request == nil || !slices.Equal(sentLines(request), []float64{3}) {
		t.Fatalf("stored %+v, want line 3 sent", stored)
	}
	h.settle()

	h.clickNamed(h.shared("native.muteBreakpoints"))
	muted := awaitValueWithin(t, h, 10*time.Second, gate.calls, "the muted breakpoints")
	exceptions, lines := muted.request("setExceptionBreakpoints"), muted.request("setBreakpoints")
	if !d.muted || muted.kind != "muted" || exceptions == nil || len(sentFilters(exceptions)) != 0 || lines == nil || len(sentLines(lines)) != 0 {
		t.Fatalf("muted %v sent %+v, want every kind empty", d.muted, muted)
	}
	if lines := d.breakpoints[source]; len(lines) != 1 || lines[0].disabled {
		t.Fatalf("muting changed the stored breakpoints: %+v", lines)
	}

	h.settle()
	h.clickNamed(h.shared("desktop.debug.unmuteBreakpoints"))
	unmuted := awaitValueWithin(t, h, 10*time.Second, gate.calls, "the unmuted breakpoints")
	exceptions, lines = unmuted.request("setExceptionBreakpoints"), unmuted.request("setBreakpoints")
	if d.muted || unmuted.kind != "unmuted" || exceptions == nil || !slices.Equal(sentFilters(exceptions), []any{"uncaught"}) ||
		lines == nil || !slices.Equal(sentLines(lines), []float64{3}) {
		t.Fatalf("muted %v sent %+v, want the default filter and line 3", d.muted, unmuted)
	}
}

// A session started while the breakpoints are muted is muted before its first breakpoint set,
// so it never stops on one; unmuting it sends the stored breakpoints.
func TestDebugSessionStartedWhileMutedStartsMuted(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "tests", "debug_source.go")
	if err := os.MkdirAll(filepath.Dir(source), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	gate := &captureBreakpointCalls{Kernel: h.app.kernel, calls: make(chan debugCall, 4)}
	h.app.kernel = gate
	p.debug.breakpoints = map[string][]debugBreakpoint{source: {{line: 3}}}
	h.clickNamed(h.shared("native.muteBreakpoints"))
	if !p.debug.muted {
		t.Fatal("the breakpoints were not muted before the start")
	}
	h.clickNamed(h.app.text.Debug.Start)
	defer releaseLaunchedDebug(h, p)
	first := awaitValueWithin(t, h, 30*time.Second, gate.calls, "the new session's first breakpoint call")
	if first.kind != "muted" {
		t.Fatalf("first call %+v, want the session muted before its breakpoints", first)
	}
	if next := awaitValueWithin(t, h, 10*time.Second, gate.calls, "the new session's breakpoints"); next.kind != "breakpoints" || next.session != first.session {
		t.Fatalf("second call %+v, want the stored breakpoints", next)
	}
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused"
	})

	h.clickNamed(h.shared("desktop.debug.unmuteBreakpoints"))
	unmuted := awaitValueWithin(t, h, 10*time.Second, gate.calls, "the unmuted breakpoints")
	if lines := unmuted.request("setBreakpoints"); unmuted.kind != "unmuted" || lines == nil || !slices.Equal(sentLines(lines), []float64{3}) {
		t.Fatalf("unmuting sent %+v, want line 3", unmuted)
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

// Every icon of the toolbar names its action in the tip that shows while the pointer rests on
// it, and while a session runs the adapter picker stays on the toolbar, switchable for the next
// session, with the status beside it naming the session only when the picker shows another
// adapter.
func TestDebugToolbarNamesItsIconsAndKeepsTheAdapterSwitchable(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d, words := &p.debug, h.app.text.Debug
	for _, name := range []string{
		h.shared("native.rerun"), words.Stop, words.Continue, words.Pause, words.StepOver, words.StepInto, words.StepOut,
		h.shared("native.viewBreakpoints"), h.shared("native.muteBreakpoints"), h.shared("native.moreActions"),
	} {
		if hint := h.pageHit(name).Hint; hint != name {
			t.Errorf("the %q icon shows the tip %q", name, hint)
		}
	}
	picker := h.pageHit(h.shared("desktop.debug.adapter"))
	stop := h.pageHit(words.Stop).Bounds
	if abs32(center(picker.Bounds).Y-center(stop).Y) > 2 || picker.Bounds.X <= stop.X {
		t.Fatalf("picker %+v is not on the toolbar row of Stop %+v", picker.Bounds, stop)
	}
	named := h.app.debugSessionLabel(d.activeSession()) + " · " + words.Paused
	if !h.shows(words.Paused) || h.shows(named) {
		t.Fatal("the status repeats the adapter the picker shows")
	}
	// A session the picker no longer shows is named by the status again.
	d.adapters = append(d.adapters, debugAdapter{PluginID: "dev.lithe.test.other", Declaration: d.adapters[0].Declaration})
	d.selectedAdapter = len(d.adapters) - 1
	h.app.invalidator.Invalidate()
	h.settle()
	if !h.shows(named) {
		t.Fatal("the status does not name the running session after the picker switched away from it")
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

// The Disassembly tab keeps the call stack on its left, as Threads & Variables does, and choosing
// another frame there shows that frame's code, not the code of the frame chosen before.
func TestDebugDisassemblyShowsTheStackBesideTheChosenFramesCode(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	d.section = debugSectionDisassembly
	h.app.invalidator.Invalidate()
	awaitStateWithin(t, h, 20*time.Second, "the instruction window", func() bool {
		return !d.disassembly.loading && len(d.disassembly.rows) > 0
	})
	// The list centres the current instruction in the frames it asks for; virtual time runs them.
	if err := h.driver.Advance(200 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	frame, code := h.pageHit("worker").Bounds, h.labelBounds("0x1000")
	if code.Width == 0 || frame.X+frame.Width > code.X {
		t.Fatalf("frame %+v is not on the left of the code %+v", frame, code)
	}

	// The fixture's second frame has no instruction pointer, so its tab has no code.
	h.click(center(frame))
	awaitStateWithin(t, h, 10*time.Second, "the second frame", func() bool { return d.vars.frame == 1 })
	h.settle()
	if len(d.disassembly.rows) != 0 || !h.shows(h.app.text.Debug.NoDisassembly) {
		t.Fatalf("the second frame shows %d rows of the first frame's code", len(d.disassembly.rows))
	}
	h.clickNamed("main")
	awaitStateWithin(t, h, 20*time.Second, "the first frame's code again", func() bool {
		return d.vars.frame == 0 && !d.disassembly.loading && len(d.disassembly.rows) > 0
	})
	if d.disassembly.anchor != "0x1000" {
		t.Fatalf("the window opened at %q, want the first frame's instruction pointer", d.disassembly.anchor)
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
		return !m.loading && m.base == "0x2000" && len(m.bytes) == int(m.window.Request.Count)
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
	if line := m.lines[0]; m.columns != 32 || len(m.lines) != len(m.bytes)/32 || line.text[line.cell[0]:line.cell[1]] != "10" {
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
		return !m.loading && m.base == "0x1000" && m.input == "0x1000" && len(m.bytes) == 4
	})
	if m.at != "" || m.mark != 0 || m.columns != 32 || m.radix != 2 {
		t.Fatalf("at %q mark %d layout %d/%d, want the instruction pointer in the kept layout", m.at, m.mark, m.columns, m.radix)
	}
}

// A frame the adapter gave no instruction pointer still reads memory at a typed address: the
// address field shows, only the way back to the current instruction is unavailable.
func TestDebugMemoryReadsAtATypedAddressOnAFrameWithoutAnInstructionPointer(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	m := &p.debug.memory
	// The fixture's second frame has no instruction pointer.
	h.app.selectDebugFrame(p, 1)
	p.debug.section = debugSectionMemory
	h.app.invalidator.Invalidate()
	h.settle()
	if m.loading || len(m.bytes) != 0 || !h.shows(h.shared("desktop.debug.memoryTypeAddress")) {
		t.Fatalf("loading %v with %d bytes; the frame without an address asks for one", m.loading, len(m.bytes))
	}
	if current, ok := h.findPageHit(h.app.text.Debug.Reload); !ok || !current.Disabled {
		t.Fatalf("the current-instruction button %+v is not disabled on a frame that has none", current)
	}

	h.typeInto(h.shared("desktop.debug.memoryAddress"), func() { m.input = "" }, "0x2010")
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the memory at the typed address", func() bool {
		return !m.loading && m.base == "0x2000" && len(m.bytes) == int(m.window.Request.Count)
	})
	if m.failure != "" || m.bytes[m.mark] != 0x10 {
		t.Fatalf("failure %q, mark %d", m.failure, m.mark)
	}
}

// An edge of the disassembly whose load failed is not loaded again by every paint that shows
// it, as it would be by a request that times out each time; Retry asks once more.
func TestDebugDisassemblyEdgeFailureWaitsForRetry(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	w := &d.disassembly
	d.section = debugSectionDisassembly
	h.app.invalidator.Invalidate()
	awaitStateWithin(t, h, 20*time.Second, "the instruction window", func() bool {
		return !w.loading && len(w.rows) > 0
	})
	if err := h.driver.Advance(200 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	rows := len(w.rows)

	// The earlier page fails as a request without an answer does.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fetch, err := h.app.kernel.PlanDebugDisassemblyWindow(ctx, "before", w.rows[0].Address, debugDisassemblyEdge, 0)
	if err != nil {
		t.Fatal(err)
	}
	w.loading = true
	h.app.reduceDisassembly(p, fetch, core.DebugDisassemblyReply{Kind: "failed", Message: "timed out"})
	awaitStateWithin(t, h, 10*time.Second, "the failed page", func() bool { return !w.loading && w.failure != "" })
	if w.failedEdge != "before" {
		t.Fatalf("failed edge %q, want before", w.failedEdge)
	}

	// The list is at its first row, where every paint would load the earlier page.
	w.list.ScrollTo(0, ui.ListStart)
	for range 5 {
		h.app.invalidator.Invalidate()
		h.settle()
		if w.loading {
			t.Fatal("a paint at the failed edge asked for it again")
		}
	}
	if len(w.rows) != rows || !h.shows("timed out") {
		t.Fatalf("%d rows, want %d with the failure shown", len(w.rows), rows)
	}

	h.clickNamed(h.shared("desktop.debug.disassemblyRetry"))
	awaitStateWithin(t, h, 20*time.Second, "the retried page", func() bool { return !w.loading && len(w.rows) > rows })
	if w.failure != "" || w.failedEdge != "" {
		t.Fatalf("failure %q edge %q after a page arrived", w.failure, w.failedEdge)
	}
}
