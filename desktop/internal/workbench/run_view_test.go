package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// The Run window gives each execution of the host its own tab, the newest selected. The tree
// beside the console says how the selected execution ended and how long it took, the console
// shows its output with the escapes decoded away, and a finished tab's × closes it and selects
// the neighbour that takes its place.
func TestRunWindowGivesEachExecutionATab(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	text := h.app.text.Run
	h.app.post(func(a *App) {
		compile := a.beginBuildOperation(p, "build", "compile", "", nil)
		feedBuildOutput(a, p, compile, "[\x1b[1;34mINFO\x1b[m] compiled\n")
		a.finishBuildTask(p, compile, json.RawMessage(`{"exitCode":0}`))
		check := a.beginBuildOperation(p, "build", "check", "", nil)
		a.finishBuildTask(p, check, json.RawMessage(`{"exitCode":1}`))
		a.reduceChrome(core.SetChromeOpen(itemRun, true))
	})
	h.settle()
	h.settle()

	compileTab, checkTab := h.pageHit("compile"), h.pageHit("check")
	if compileTab.Role != gfx.RoleTab || checkTab.Role != gfx.RoleTab || compileTab.Selected || !checkTab.Selected {
		t.Fatalf("tabs compile %+v and check %+v, want two tabs with the newest selected", compileTab, checkTab)
	}
	// The virtual clock does not move inside one post, so each execution took no time.
	if _, ok := h.findPageHit("check, " + text.Failed + ", " + text.Duration(0)); !ok {
		t.Fatal("the tree does not say the selected execution failed and how long it took")
	}

	h.clickNamed("compile")
	h.settle()
	if _, ok := h.findPageHit("compile, " + text.Succeeded + ", " + text.Duration(0)); !ok {
		t.Fatal("choosing a tab does not show its execution in the tree")
	}
	// A styled line draws one label for each run of the same style.
	if !h.shows("INFO") || !h.shows("] compiled") || h.shows("\x1b") || h.shows("[1;34m") {
		t.Fatal("the console does not show the execution's output without its escapes")
	}

	h.click(center(closeButtonIn(h, h.pageHit("compile").Bounds, text.CloseSession).Bounds))
	h.settle()
	if len(p.build.runs) != 1 || p.activeRun() == nil || p.activeRun().label != "check" {
		t.Fatalf("closing the shown tab left %d tabs showing %v, want the check tab alone", len(p.build.runs), p.activeRun())
	}
	if _, ok := h.findPageHit("compile"); ok {
		t.Fatal("the closed tab stays on screen")
	}
}

// closeButtonIn is the control named label inside the bounds of tab.
func closeButtonIn(h *harness, tab gfx.Rect, label string) gfx.Hit {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		b := hit.Bounds
		if hit.Label == label && !hit.IsLabel && b.X >= tab.X && b.Y >= tab.Y && b.X+b.Width <= tab.X+tab.Width && b.Y+b.Height <= tab.Y+tab.Height {
			return hit
		}
	}
	h.t.Fatalf("no %q control inside the tab at %+v", label, tab)
	return gfx.Hit{}
}
