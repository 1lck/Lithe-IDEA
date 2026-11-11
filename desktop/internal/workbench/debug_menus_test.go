package workbench

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/vivaui/viva/gfx"
)

// The Debug tool window's context menus copy what a stack frame, an instruction and a variable
// show, show a frame's disassembly and the memory at an instruction, and remove the line
// breakpoints, as the earlier client's debugger did.
func TestDebugMenusCopyFramesAndVariablesAndRemoveBreakpoints(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	d := &p.debug
	// The variables tree sits under the watch editor; a tall window leaves the bottom panel room
	// for it.
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()

	// The row of the thread picker copies the selected thread's name.
	awaitStateWithin(t, h, 20*time.Second, "the adapter's threads", func() bool { return len(d.threads) == 2 })
	h.settle()
	var threads gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == h.app.text.Debug.Threads && !hit.IsLabel && hit.Bounds.Width > threads.Width {
			threads = hit.Bounds
		}
	}
	h.rightClickAt(gfx.Rect{X: threads.X + threads.Width - 40, Y: threads.Y, Width: 20, Height: threads.Height})
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
	address := d.disassembly.rows[1].Address
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
	h.clickNamed(h.app.text.Debug.Variables)
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

	// A line breakpoint is removed with the others.
	source := d.frames[0].SourcePath
	d.breakpoints = map[string][]debugBreakpoint{source: {{line: 3}, {line: 5}}}
	h.app.sendDebugBreakpoints(p, source)
	h.settle()
	h.rightClickNamed(filepath.Base(source) + ":3")
	h.click(center(h.popupHit(h.shared("native.removeAll"))))
	if len(d.breakpoints) != 0 {
		t.Fatalf("breakpoints = %+v, want none", d.breakpoints)
	}
}
