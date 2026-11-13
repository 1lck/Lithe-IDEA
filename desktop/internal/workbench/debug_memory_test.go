package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDebugMemoryLinesFormatOffsetsRadixAndText(t *testing.T) {
	data := []byte{0x48, 0x8b, 0x05, 0x10, 'A', 0x00}
	lines := debugMemoryLines(data, 0, false, 16, 16, -1)
	if len(lines) != 1 {
		t.Fatalf("lines = %#v, want one row", lines)
	}
	line := lines[0]
	for _, want := range []string{"0000  ", "48 8b 05 10 41 00", "H...A."} {
		if !strings.Contains(line.text, want) {
			t.Fatalf("line = %q, want it to contain %q", line.text, want)
		}
	}
	if line.cell != [2]int{} || line.char != [2]int{} {
		t.Fatalf("an unmarked row marks %v %v", line.cell, line.char)
	}
	if got := debugMemoryLines(nil, 0, false, 16, 16, -1); got != nil {
		t.Fatalf("empty memory = %#v, want no rows", got)
	}
	// A full row keeps its trailing text and a second row starts at the row width.
	lines = debugMemoryLines(make([]byte, 17), 0, false, 16, 16, -1)
	if len(lines) != 2 || !strings.HasPrefix(lines[1].text, "0010  ") {
		t.Fatalf("two rows = %#v", lines)
	}
	lines = debugMemoryLines(make([]byte, 33), 0, false, 32, 16, -1)
	if len(lines) != 2 || !strings.HasPrefix(lines[1].text, "0020  ") {
		t.Fatalf("rows of 32 = %#v", lines)
	}

	// Every base writes the same bytes in its own digits.
	for radix, want := range map[int]string{2: "01001000 10001011", 8: "110 213", 10: " 72 139", 16: "48 8b"} {
		if text := debugMemoryLines(data[:2], 0, false, 16, radix, -1)[0].text; !strings.Contains(text, want) {
			t.Fatalf("base %d row = %q, want %q", radix, text, want)
		}
	}

	// An absolute window is labelled with addresses and the marked byte's cell and character
	// are found in the row that holds it.
	lines = debugMemoryLines(data, 0x100000470, true, 4, 16, 5)
	if len(lines) != 2 || !strings.HasPrefix(lines[1].text, "0x100000474  ") {
		t.Fatalf("absolute rows = %#v", lines)
	}
	marked := lines[1]
	if lines[0].cell != [2]int{} || marked.text[marked.cell[0]:marked.cell[1]] != "00" || marked.text[marked.char[0]:marked.char[1]] != "." {
		t.Fatalf("mark at byte 5 = %q cell %v char %v", marked.text, marked.cell, marked.char)
	}
	if got := marked.text[lines[1].char[0]-1 : marked.char[0]]; got != "A" {
		t.Fatalf("the character before the mark is %q, want A", got)
	}
}

func TestParseDebugAddressReadsHexAndDecimal(t *testing.T) {
	for text, want := range map[string]uint64{"0x1000": 0x1000, " 0X1f ": 0x1f, "4096": 4096} {
		if got, ok := parseDebugAddress(text); !ok || got != want {
			t.Fatalf("parse %q = %d %v, want %d", text, got, ok, want)
		}
	}
	for _, text := range []string{"", "0x", "frame:1", "-4"} {
		if _, ok := parseDebugAddress(text); ok {
			t.Fatalf("parse %q succeeded; an opaque reference is not a number", text)
		}
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
	if p.debug.memory.mark != 0 || p.debug.memory.input != "0x1000" {
		t.Fatalf("mark %d input %q, want the instruction pointer's byte and address", p.debug.memory.mark, p.debug.memory.input)
	}

	// The toolbar steps by the adapter's default unit. The adapter writes the
	// step reply, its output and `stopped` as separate frames that may arrive in
	// separate reads, so each step waits for the stop to be applied, not just
	// for the output that precedes it.
	h.clickNamed(h.app.text.Debug.StepOver)
	awaitStateWithin(t, h, 20*time.Second, "the statement step", func() bool {
		return p.debug.state == "paused" && strings.Contains(strings.Join(p.debug.output, ""), "stepped statement") && p.debug.failure == ""
	})

	// The disassembly view steps one instruction: the fixture refuses anything
	// but the instruction granularity, so a success proves Core forwarded it.
	h.app.executeDebugWithGranularity(p, "stepIn", "instruction")
	awaitStateWithin(t, h, 20*time.Second, "the instruction step", func() bool {
		return p.debug.state == "paused" && strings.Contains(strings.Join(p.debug.output, ""), "stepped instruction") && p.debug.failure == ""
	})

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
		return p.debug.activeSession() == nil
	})
}
