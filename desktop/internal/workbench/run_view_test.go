package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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

// Sessions from the same plugin aggregate under one group tab in the Run header, list each
// execution in the left tree so clicking switches consoles, and collapse detail lines behind
// a disclosure chevron until expanded.
func TestRunWindowAggregatesPluginSessionsAndFoldsDetails(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	text := h.app.text.Run

	instance := &buildInstance{
		BuildInstance: core.BuildInstance{ID: "fixture-root", BuildSystemID: "fixture", DisplayName: "Fixture"},
		PluginID:      "dev.lithe.test.build",
		System:        pluginservice.BuildSystemDeclaration{DisplayName: "Fixture"},
	}

	h.app.post(func(a *App) {
		syncFeed := a.beginBuildSync(p, instance)
		syncFeed.decoder.deliver("sync ok\n", func(chunk outputChunk, _ error) {
			syncFeed.session.output.apply(chunk)
		})
		a.endBuildSync(syncFeed.session, nil)

		clean := a.beginBuildOperation(p, "build", "Fixture: clean", "", nil)
		setRunGroupFromInstance(p, clean.session, instance)
		feedBuildOutput(a, p, clean, "clean ok\n")
		a.finishBuildTask(p, clean, json.RawMessage(`{"exitCode":0}`))

		a.reduceChrome(core.SetChromeOpen(itemRun, true))
	})
	h.settle()
	h.settle()

	// Both sessions share one aggregated tab named after the plugin's build system.
	groupTab := h.pageHit("Fixture")
	if groupTab.Role != gfx.RoleTab || !groupTab.Selected {
		t.Fatalf("group tab = %+v, want selected tab named Fixture", groupTab)
	}
	if _, ok := h.findPageHit("Fixture: clean"); ok {
		t.Fatal("grouped session should not appear as a separate top-level tab before detaching")
	}

	// Both sessions appear in the left execution tree, and detail lines are collapsed by default.
	syncLabel := h.app.buildSyncLabel(instance)
	cleanNode := h.pageHit("Fixture: clean, " + text.Succeeded + ", " + text.Duration(0))
	syncNode := h.pageHit(syncLabel + ", " + text.Succeeded + ", " + text.Duration(0))
	if !cleanNode.Selected || syncNode.Selected {
		t.Fatalf("tree selection clean=%v sync=%v, want clean selected", cleanNode.Selected, syncNode.Selected)
	}
	if h.shows(h.app.text.Build.Succeeded) {
		t.Fatal("build summary should be collapsed behind the disclosure chevron by default")
	}
	if !h.shows("clean ok") {
		t.Fatal("console does not show the selected session's output")
	}

	// Clicking the disclosure chevron expands the detail row, and clicking again collapses it.
	expandBtn := closeButtonIn(h, cleanNode.Bounds, text.ExpandDetails)
	h.click(center(expandBtn.Bounds))
	h.settle()
	if !h.shows(h.app.text.Build.Succeeded) {
		t.Fatal("expanding the disclosure chevron did not reveal the build summary")
	}
	collapseBtn := closeButtonIn(h, h.pageHit("Fixture: clean, "+text.Succeeded+", "+text.Duration(0)).Bounds, text.CollapseDetails)
	h.click(center(collapseBtn.Bounds))
	h.settle()
	if h.shows(h.app.text.Build.Succeeded) {
		t.Fatal("collapsing the disclosure chevron did not hide the build summary")
	}

	// Clicking the other session in the tree switches the console on the right.
	h.click(center(syncNode.Bounds))
	h.settle()
	if !h.shows("sync ok") {
		t.Fatal("clicking another session in the group tree did not switch the console")
	}
}

// Dragging a grouped session row from the Run tree up to the header tab bar detaches it into
// its own tab, and dragging that detached tab back onto its sibling tab merges them again.
func TestRunWindowDragDetachesSessionToTabAndMergesBack(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	text := h.app.text.Run

	instance := &buildInstance{
		BuildInstance: core.BuildInstance{ID: "fixture-root", BuildSystemID: "fixture", DisplayName: "Fixture"},
		PluginID:      "dev.lithe.test.build",
		System:        pluginservice.BuildSystemDeclaration{DisplayName: "Fixture"},
	}

	h.app.post(func(a *App) {
		syncFeed := a.beginBuildSync(p, instance)
		a.endBuildSync(syncFeed.session, nil)

		clean := a.beginBuildOperation(p, "build", "Fixture: clean", "", nil)
		setRunGroupFromInstance(p, clean.session, instance)
		a.finishBuildTask(p, clean, json.RawMessage(`{"exitCode":0}`))

		a.reduceChrome(core.SetChromeOpen(itemRun, true))
	})
	h.settle()
	h.frames()

	// Drag the "Fixture: clean" tree row up to the right side of the Run tab bar.
	cleanNode := h.pageHit("Fixture: clean, " + text.Succeeded + ", " + text.Duration(0))
	bar := h.app.dnd.runPlaces.tabBar
	if bar.Width <= 0 || bar.Height <= 0 {
		t.Fatalf("tabBar rect = %+v, want non-empty", bar)
	}
	h.drag(center(cleanNode.Bounds), gfx.Point{X: bar.X + bar.Width - 20, Y: bar.Y + bar.Height/2})
	h.settle()
	h.frames()

	if h.app.dnd.run.Dragging() || h.app.dnd.runDrag.active {
		t.Fatal("drag did not finish after release")
	}
	syncLabel := h.app.buildSyncLabel(instance)
	syncTab, cleanTab := h.pageHit(syncLabel), h.pageHit("Fixture: clean")
	if syncTab.Role != gfx.RoleTab || cleanTab.Role != gfx.RoleTab || !cleanTab.Selected {
		t.Fatalf("after detach: syncTab=%+v cleanTab=%+v, want two tabs with Fixture: clean selected", syncTab, cleanTab)
	}

	// Drag the detached "Fixture: clean" tab back onto the "Sync Fixture" tab to re-aggregate.
	h.drag(center(cleanTab.Bounds), center(syncTab.Bounds))
	h.settle()
	h.frames()

	groupTab := h.pageHit("Fixture")
	if groupTab.Role != gfx.RoleTab || !groupTab.Selected {
		t.Fatalf("after merge: groupTab=%+v, want single aggregated Fixture tab", groupTab)
	}
	if _, ok := h.findPageHit("Fixture: clean"); ok {
		t.Fatal("merged session should no longer be a separate tab")
	}
}
