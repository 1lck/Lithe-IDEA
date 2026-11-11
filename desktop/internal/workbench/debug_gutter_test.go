package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// A press on a line number adds the line's breakpoint and a second one removes it; the gutter
// shows the file's breakpoints as they are, disabled ones included, and the paused line is tinted
// while the selected frame stops in the file, as the earlier client's editor showed them.
func TestEditorGutterTogglesBreakpointsAndShowsThePausedLine(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "main.go")
	if err := os.WriteFile(source, []byte("package main\n\nfunc main() {\n\tprintln()\n}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.openFileAtPosition(p, source, 0, 0)
	h.settle()
	d := p.docs.byPath(source)
	if d == nil {
		t.Fatal("the file did not open")
	}
	var editor gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == d.hit {
			editor = hit.Bounds
		}
	}
	if editor.Width == 0 {
		t.Fatal("the editor declared no hit")
	}
	// The line numbers' column, clear of the Git bar at its left edge.
	number := func(line int) gfx.Point {
		return gfx.Point{X: editor.X + 16, Y: d.view.LineTop(line) + d.view.LineHeight()/2}
	}

	h.click(number(3))
	h.settle()
	if got := p.debug.breakpoints[source]; len(got) != 1 || got[0].line != 4 {
		t.Fatalf("breakpoints = %+v, want line 4", got)
	}
	if shown := d.debugGutter.shown; len(shown) != 1 || shown[0].Line != 3 || shown[0].Disabled {
		t.Fatalf("the gutter shows %+v, want an enabled breakpoint on line 4", shown)
	}
	h.app.post(func(a *App) { a.setBreakpointEnabled(p, source, 4, false) })
	h.settle()
	if shown := d.debugGutter.shown; len(shown) != 1 || !shown[0].Disabled {
		t.Fatalf("the gutter shows %+v, want the breakpoint disabled", shown)
	}

	h.app.post(func(a *App) {
		p.debug.state = "paused"
		p.debug.frames = []core.DebugStackFrame{{Name: "main", SourcePath: source, Line: 4}}
	})
	h.settle()
	if d.debugGutter.execution != 3 {
		t.Fatalf("the paused line is %d, want line 4", d.debugGutter.execution)
	}
	h.app.post(func(a *App) { p.debug.state, p.debug.frames = "", nil })
	h.settle()
	if d.debugGutter.execution != -1 {
		t.Fatalf("the paused line %d stayed after the debuggee went on", d.debugGutter.execution)
	}

	h.click(number(3))
	h.settle()
	if got := p.debug.breakpoints[source]; len(got) != 0 {
		t.Fatalf("breakpoints = %+v, want none after the second press", got)
	}
	if len(d.debugGutter.shown) != 0 {
		t.Fatalf("the gutter still shows %+v", d.debugGutter.shown)
	}
}
