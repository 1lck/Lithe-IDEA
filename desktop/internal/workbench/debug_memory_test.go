package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDebugMemoryLinesFormatOffsetsHexAndText(t *testing.T) {
	lines := debugMemoryLines([]byte{0x48, 0x8b, 0x05, 0x10, 'A', 0x00})
	if len(lines) != 1 {
		t.Fatalf("lines = %#v, want one row", lines)
	}
	line := lines[0]
	for _, want := range []string{"0000  ", "48 8b 05 10 41 00", "H...A."} {
		if !strings.Contains(line, want) {
			t.Fatalf("line = %q, want it to contain %q", line, want)
		}
	}
	if got := debugMemoryLines(nil); got != nil {
		t.Fatalf("empty memory = %#v, want no rows", got)
	}
	// A full row keeps its trailing text and a second row starts at 0x10.
	lines = debugMemoryLines(make([]byte, debugMemoryColumns+1))
	if len(lines) != 2 || !strings.HasPrefix(lines[1], "0010  ") {
		t.Fatalf("two rows = %#v", lines)
	}
}

func TestDebugMemoryReadsWithoutComputedAddresses(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "tests", "debug_source.go")
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()
	pauseDebugFixture(t, h, p)
	if capabilities := p.debug.capabilities; capabilities == nil || !capabilities.SupportsReadMemoryRequest || !capabilities.SupportsSteppingGranularity {
		t.Fatalf("capabilities = %+v, want memory and stepping", capabilities)
	}

	h.app.loadDebugMemory(p)
	awaitStateWithin(t, h, 20*time.Second, "the memory window", func() bool {
		return len(p.debug.memory.bytes) == 4 && p.debug.memory.address == "0x1000"
	})
	if p.debug.memory.unreadable != 2 {
		t.Fatalf("unreadable bytes = %d, want 2", p.debug.memory.unreadable)
	}
	if got := debugMemoryLines(p.debug.memory.bytes)[0]; !strings.Contains(got, "48 8b 05 10") {
		t.Fatalf("memory line = %q", got)
	}

	// The toolbar steps by the adapter's default unit.
	h.clickNamed(h.app.text.Debug.StepOver)
	awaitStateWithin(t, h, 20*time.Second, "the statement step", func() bool {
		return strings.Contains(strings.Join(p.debug.output, ""), "stepped statement") && p.debug.failure == ""
	})

	// The disassembly view steps one instruction: the fixture refuses anything
	// but the instruction granularity, so a success proves Core forwarded it.
	h.app.executeDebugWithGranularity(p, "stepIn", "instruction")
	awaitStateWithin(t, h, 20*time.Second, "the instruction step", func() bool {
		return strings.Contains(strings.Join(p.debug.output, ""), "stepped instruction") && p.debug.failure == ""
	})
	if p.debug.state != "paused" {
		t.Fatalf("state = %q, want paused after the step", p.debug.state)
	}

	// The memory tab is offered only with the capability and shows the bytes.
	// The step reset the window; the memory tab reloads it from the new stop.
	p.debug.section = debugSectionMemory
	h.app.invalidator.Invalidate()
	awaitStateWithin(t, h, 20*time.Second, "the memory window after the step", func() bool {
		return len(p.debug.memory.bytes) == 4 && p.debug.memory.unreadable == 2
	})
	if !h.shows("内存") || !h.shows("无法读取的字节：2") {
		t.Fatal("the Debug panel does not show the memory view")
	}
	h.clickNamed(h.app.text.Debug.Stop)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		return p.debug.session == nil
	})
}
