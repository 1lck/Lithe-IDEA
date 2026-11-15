package term

import (
	"runtime"
	"strings"
	"testing"
	"weak"
)

// collected reports whether ref became unreachable. Collection needs more than
// one cycle when a value was still on a stack in an earlier cycle.
func collected[T any](ref weak.Pointer[T]) bool {
	for range 5 {
		runtime.GC()
		if ref.Value() == nil {
			return true
		}
	}
	return false
}

// Growing the window pulls history lines back onto the screen. The line that
// leaves the history ring used to stay referenced by the ring's backing array,
// so a temporary tall window held a whole scrollback's worth of cells that were
// no longer history.
func TestGrowingTheWindowReleasesPoppedHistory(t *testing.T) {
	term := New(40, 5, 100)
	for range 200 {
		term.Write([]byte("a line of output\r\n"))
	}
	newest := term.histAt(term.histCount - 1)
	ref := weak.Make(newest)
	newest = nil
	term.Resize(40, 100)
	if !collected(ref) {
		t.Fatal("a line popped from history is still reachable from the terminal")
	}
	runtime.KeepAlive(term)
}

// A line limit is not a memory limit: at 500 columns the same 5000 lines cost
// several times what they do at 120. The byte budget must give the oldest
// lines back instead of letting a wide terminal grow without bound.
func TestWideHistoryStaysWithinItsByteBudget(t *testing.T) {
	term := New(500, 24, DefaultScrollback)
	term.histBudget = 64 << 10
	line := []byte(strings.Repeat("x", 500) + "\r\n")
	for range 200 {
		term.Write(line)
	}
	checkInvariants(t, term)
	if term.histBytes > term.histBudget {
		t.Fatalf("history holds %d bytes, budget %d", term.histBytes, term.histBudget)
	}
	if lines := term.Scrollback(); lines == 0 || lines >= DefaultScrollback {
		t.Fatalf("scrollback = %d, want some lines but fewer than the line limit", lines)
	}
	// Raising the line limit must not undo the byte bound.
	term.SetScrollbackLimit(2 * DefaultScrollback)
	if term.histBytes > term.histBudget || term.Scrollback() > 2*DefaultScrollback {
		t.Fatalf("after raising the limit: %d lines, %d bytes (budget %d)", term.Scrollback(), term.histBytes, term.histBudget)
	}
}
