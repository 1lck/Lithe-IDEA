package workbench

import (
	"path/filepath"
	"testing"
	"time"
)

// The Debug tool window's context menus copy what a stack frame, an instruction and a variable
// show, show a frame's disassembly and the memory at an instruction, and disable, enable and
// remove the line breakpoints, as the earlier client's debugger did.
func TestDebugMenusCopyFramesAndVariablesAndToggleBreakpoints(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	// The variables tree sits under the watch editor; a tall window leaves the bottom panel room
	// for it.
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()

	// A stack frame's menu ends with its thread's items, which copy the thread's name.
	awaitStateWithin(t, h, 20*time.Second, "the adapter's threads", func() bool { return len(d.threads) == 2 })
	h.settle()
	h.rightClickNamed("main")
	h.click(center(h.popupHit(h.shared("native.copyThreadName"))))
	if got := h.driver.Clipboard(); got != "main" {
		t.Fatalf("the clipboard holds %q, want the stopped thread's name", got)
	}

	// A stack frame copies its method name, its address and its location in its file.
	h.rightClickNamed("main")
	h.click(center(h.popupHit(h.shared("native.copyMethodName"))))
	if got := h.driver.Clipboard(); got != "main" {
		t.Fatalf("the clipboard holds %q, want the method name", got)
	}
	h.rightClickNamed("main")
	h.click(center(h.popupHit(h.shared("debugger.disassembly.copyAddress"))))
	if got := h.driver.Clipboard(); got != "0x1000" {
		t.Fatalf("the clipboard holds %q, want the frame's address", got)
	}
	h.rightClickNamed("main")
	h.click(center(h.popupHit(h.shared("native.copyRelativeLocation"))))
	if got, want := h.driver.Clipboard(), filepath.Base(d.frames[0].SourcePath)+":3:1"; got != want {
		t.Fatalf("the clipboard holds %q, want %q", got, want)
	}
	h.rightClickNamed("main")
	h.click(center(h.popupHit(h.shared("debugger.disassembly.showDisassembly"))))
	if d.section != debugSectionDisassembly {
		t.Fatalf("section = %q, want the disassembly", d.section)
	}

	// An instruction copies its address and has the memory at that address read.
	awaitStateWithin(t, h, 20*time.Second, "the instruction window", func() bool { return !d.disassembly.loading && len(d.disassembly.rows) > 1 })
	h.settle()
	// The window opens centred on the current instruction: the one after it is in view, the
	// first row of the window is scrolled away above, and nothing more was loaded for it.
	address := "0x1004"
	// The list measures its rows in the frames it asks for after the first layout; virtual
	// time runs them.
	if err := h.driver.Advance(200 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if !h.shows(address) || h.shows("0xfa0") {
		t.Fatalf("the window did not open centred on the current instruction")
	}
	if rows := len(d.disassembly.rows); rows != 96 {
		t.Fatalf("the window holds %d instructions after it opened, want the 96 of the first window", rows)
	}
	h.rightClickAt(h.labelBounds(address))
	h.click(center(h.popupHit(h.shared("debugger.disassembly.copyAddress"))))
	if got := h.driver.Clipboard(); got != address {
		t.Fatalf("the clipboard holds %q, want the instruction's address %q", got, address)
	}
	h.rightClickAt(h.labelBounds(address))
	h.click(center(h.popupHit(h.shared("debugger.disassembly.readMemoryAtAddress"))))
	if d.section != debugSectionMemory || d.memory.at != address {
		t.Fatalf("section %q reads at %q, want the memory at %q", d.section, d.memory.at, address)
	}
	awaitStateWithin(t, h, 20*time.Second, "the memory read", func() bool { return !d.memory.loading && len(d.memory.bytes) > 0 })

	// A variable copies its value and its name, and Set Value shows the field for it.
	h.showDebugSection(h.shared("debugger.threadsAndVariables"))
	h.rightClickNamed("count = 1")
	h.click(center(h.popupHit(h.shared("native.copyValue"))))
	if got := h.driver.Clipboard(); got != "1" {
		t.Fatalf("the clipboard holds %q, want the variable's value", got)
	}
	h.rightClickNamed("count = 1")
	h.click(center(h.popupHit(h.shared("native.copyName"))))
	if got := h.driver.Clipboard(); got != "count" {
		t.Fatalf("the clipboard holds %q, want the variable's name", got)
	}
	h.rightClickNamed("count = 1")
	h.click(center(h.popupHit(h.shared("native.setValue"))))
	if selected := d.vars.selected; selected == nil || selected.name != "count" {
		t.Fatalf("Set Value selected %+v, want count", selected)
	}

	// The Breakpoints dialog lists the line breakpoints; one is removed with the others.
	source := d.frames[0].SourcePath
	d.breakpoints = map[string][]debugBreakpoint{source: {{line: 3}, {line: 5}}}
	h.app.sendDebugBreakpoints(p, source)
	h.clickNamed(h.shared("native.viewBreakpoints"))
	// A line breakpoint is disabled and enabled again; a disabled one keeps its line and is
	// sent as disabled, so Core leaves it out of what the adapter gets.
	h.rightClickNamed(filepath.Base(source) + ":3")
	h.click(center(h.popupHit(h.shared("debugger.disableBreakpoint"))))
	if points := sourceBreakpoints(d.breakpoints[source]); len(points) != 2 || points[0].Enabled || !points[1].Enabled {
		t.Fatalf("after Disable the file sends %+v, want line 3 disabled", points)
	}
	h.settle()
	h.rightClickNamed(filepath.Base(source) + ":3")
	h.click(center(h.popupHit(h.shared("debugger.enableBreakpoint"))))
	if d.breakpoints[source][0].disabled {
		t.Fatal("Enable left line 3 disabled")
	}
	h.settle()
	h.rightClickNamed(filepath.Base(source) + ":3")
	h.click(center(h.popupHit(h.shared("native.removeAll"))))
	if len(d.breakpoints) != 0 {
		t.Fatalf("breakpoints = %+v, want none", d.breakpoints)
	}
}
