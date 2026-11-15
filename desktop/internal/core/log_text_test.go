package core

import (
	"runtime/debug"
	"strings"
	"testing"
)

func TestLogTextKeepsOneBoundedLine(t *testing.T) {
	if got := LogText("index out of range\n\t[3] with\x00 length 2  "); got != "index out of range [3] with length 2" {
		t.Fatalf("LogText = %q", got)
	}
	long := strings.Repeat("é", 600)
	got := LogText(long)
	if len(got) > logTextLimit || !strings.HasPrefix(long, got) || len(got) != 1024 {
		t.Fatalf("LogText cut %d bytes to %d", len(long), len(got))
	}
}

func TestLogFirstLineReadsTheCrashHeadline(t *testing.T) {
	text := "\n\npanic: runtime error: invalid memory address or nil pointer dereference\n[signal SIGSEGV]\n\ngoroutine 1 [running]:\n"
	if got := LogFirstLine(text); got != "panic: runtime error: invalid memory address or nil pointer dereference" {
		t.Fatalf("LogFirstLine = %q", got)
	}
	if got := LogFirstLine(" \n\t\n"); got != "" {
		t.Fatalf("LogFirstLine of blank text = %q", got)
	}
}

func TestLogTokenNormalizesFaultBoundaries(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"darwin: AppKit callback", "darwin:appkit-callback"},
		{"darwin: AppKit fullscreen callback", "darwin:appkit-fullscreen-callback"},
		{"windows: shortcut handler", "windows:shortcut-handler"},
		{"status icon window procedure", "status-icon-window-procedure"},
		{"  -- odd (name) --  ", "odd-name"},
		{"UI Automation / IAccessible", "ui-automation/iaccessible"},
		{"界面", "unknown"},
		{"", "unknown"},
		{strings.Repeat("a", 63) + " b", strings.Repeat("a", 63)},
	} {
		if got := LogToken(c.in); got != c.want {
			t.Errorf("LogToken(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

//go:noinline
func panicFixture() {
	panic("fixture")
}

// recoveredStack recovers panicFixture's panic the way a boundary does and returns the stack
// debug.Stack prints there.
func recoveredStack() (stack []byte) {
	defer func() {
		if recover() != nil {
			stack = debug.Stack()
		}
	}()
	panicFixture()
	return nil
}

func TestLogPanicStackStartsAtThePanickingFrame(t *testing.T) {
	got := LogPanicStack(recoveredStack())
	if !strings.HasPrefix(got, "core.panicFixture log_text_test.go:") ||
		!strings.Contains(got, " < core.recoveredStack log_text_test.go:") {
		t.Fatalf("LogPanicStack = %q", got)
	}
	for _, leaked := range []string{"debug.Stack", "panic ", "/", "+0x", "\t"} {
		if strings.Contains(got, leaked) {
			t.Fatalf("LogPanicStack = %q, which contains %q", got, leaked)
		}
	}
}

func TestLogPanicStackReadsACrashReport(t *testing.T) {
	report := "panic: boom [recovered]\n\tpanic: boom\n\n" +
		"goroutine 7 [running]:\n" +
		"github.com/1lck/Lithe-IDEA/desktop/internal/workbench.(*App).draw.func1()\n" +
		"\t/Users/someone/src/desktop/internal/workbench/app.go:910 +0x5c\n" +
		"panic({0x1006c8e40?, 0x1400012a0b0?})\n" +
		"\t/usr/local/go/src/runtime/panic.go:787 +0x124\n" +
		"github.com/1lck/Lithe-IDEA/desktop/internal/workbench.parse[...](...)\n" +
		"\tC:/Users/someone/src/desktop/internal/workbench/parse.go:12\n" +
		"github.com/1lck/Lithe-IDEA/desktop/internal/workbench.(*App).draw(0x14000156000, {0x1, 0x2})\n" +
		"\t/Users/someone/src/desktop/internal/workbench/app.go:905 +0x30\n" +
		"...additional frames elided...\n" +
		"created by github.com/1lck/Lithe-IDEA/desktop/internal/workbench.(*App).Run in goroutine 1\n" +
		"\t/Users/someone/src/desktop/internal/workbench/app.go:840 +0x88\n" +
		"\n" +
		"goroutine 1 [chan receive]:\n" +
		"main.main()\n" +
		"\t/Users/someone/src/desktop/cmd/lithe/main.go:40 +0x10\n"
	want := "workbench.parse[...] parse.go:12 < workbench.(*App).draw app.go:905 < created by workbench.(*App).Run app.go:840"
	if got := LogPanicStack([]byte(report)); got != want {
		t.Fatalf("LogPanicStack =\n%q\nwant\n%q", got, want)
	}
}

func TestLogPanicStackOfAFatalErrorKeepsTheProgramFrames(t *testing.T) {
	report := "fatal error: concurrent map writes\n\n" +
		"goroutine 9 [running]:\n" +
		"internal/runtime/maps.fatal({0x100f, 0x15})\n" +
		"\t/usr/local/go/src/runtime/panic.go:1058 +0x20\n" +
		"runtime.mapassign_faststr(0x1, 0x2, {0x3, 0x4})\n" +
		"\t/usr/local/go/src/runtime/map_faststr.go:264 +0x2c\n" +
		"main.record(...)\n" +
		"\t/src/main.go:20\n"
	want := "main.record main.go:20"
	if got := LogPanicStack([]byte(report)); got != want {
		t.Fatalf("LogPanicStack = %q, want %q", got, want)
	}
}

func TestLogPanicStackStopsAtAFrameWithinTheLimit(t *testing.T) {
	var report strings.Builder
	report.WriteString("goroutine 1 [running]:\n")
	for range 200 {
		report.WriteString("example.com/pkg.deeplyNestedFunctionName()\n\t/src/pkg/file.go:1 +0x1\n")
	}
	got := LogPanicStack([]byte(report.String()))
	if len(got) > logTextLimit || !strings.HasSuffix(got, "pkg.deeplyNestedFunctionName file.go:1") {
		t.Fatalf("LogPanicStack is %d bytes and ends %q", len(got), got[max(0, len(got)-40):])
	}
	if LogPanicStack(nil) != "" || LogPanicStack([]byte("no goroutine here")) != "" {
		t.Fatal("LogPanicStack of text without a stack is not empty")
	}
}
