package workbench

import (
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// buildSyncWait bounds each wait for a model load of the fixture build tool; it is shorter than
// the hang modes' sleep, so a load that ends within it was ended by the host.
const buildSyncWait = 10 * time.Second

// openBuildCommand opens the command fixture's build system at the workspace root as the only
// detected one, its group open and its model not loaded yet. The Build window stays closed, so
// no view starts a load of its own.
func openBuildCommand(t *testing.T) (*harness, *recordingPluginKernel, *project) {
	t.Helper()
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	instance := buildCommandInstance(".", false)
	instance.System.DisplayName = "Fixture"
	h.app.post(func(a *App) {
		p.build.instances, p.build.loaded, p.build.selected = []buildInstance{instance}, true, 0
	})
	h.settle()
	p.setBuildGroupOpen(0, true)
	return h, plugins, p
}

// buildModelNote is the Build tree's line about the fixture's model: loading, failed or stopped.
func buildModelNote(t *testing.T, h *harness, p *project) buildRow {
	t.Helper()
	rows, _ := h.app.buildTreeRows(p)
	for _, row := range rows {
		if row.kind == buildRowEmpty && (row.loading || row.model) {
			return row
		}
	}
	t.Fatalf("the Build tree has no line about the model: %q", buildTreeShape(rows))
	return buildRow{}
}

// buildSyncSessions counts the Run window's sessions of model loads.
func buildSyncSessions(p *project) int {
	count := 0
	for _, entry := range p.build.runs {
		if entry.sync != nil {
			count++
		}
	}
	return count
}

// A model load is a session of the Run window named after its build system. What the tool logs
// on stderr while stdout carries the model, as `go list` logs the modules it downloads, shows
// in the session's console and does not spoil the model's decoding; the session ends succeeded
// without bringing the Run window forward.
func TestBuildModelLoadShowsTheToolsLogInARunWindowSession(t *testing.T) {
	h, plugins, p := openBuildCommand(t)
	writeBuildCommandMarker(t, p.root, "download")
	h.app.loadBuildModel(p, 0)
	session := p.buildSyncSession(p.build.instances[0].ID)
	label := i18n.SharedFormat(h.app.language(), "desktop.build.syncSession", map[string]string{"name": "Fixture"})
	if session == nil || !session.running || session.label != label || p.build.view != session.id {
		t.Fatalf("the load opened session %+v, want the running session %q shown", session, label)
	}
	if h.app.chrome.isOpen(h.app.chrome.index[itemRun]) {
		t.Fatal("a model load brought the Run window forward")
	}
	awaitStateWithin(t, h, buildSyncWait, "the model load to end", func() bool { return !p.build.instances[0].modelLoading })

	instance := &p.build.instances[0]
	if !instance.modelLoaded || instance.modelError != "" || len(instance.Model.Projects) != 1 {
		t.Fatalf("a model whose tool logged a download on stderr: loaded %v, error %q, model %+v", instance.modelLoaded, instance.modelError, instance.Model)
	}
	if session.running || session.outcome != runSucceeded || session.ended.IsZero() || session.summary != "" || session.sync.latest != "" {
		t.Fatalf("the finished session = running %v, outcome %v, ended %v, summary %q, latest %q", session.running, session.outcome, session.ended, session.summary, session.sync.latest)
	}
	if console := session.output.all(); !strings.Contains(console, buildCommandDownloadLine) {
		t.Fatalf("the session's console = %q, want the tool's download line", console)
	}
	got := plugins.next(t, "the model load")
	if got.Operation != core.OperationBuildModel || got.Outcome != "finished" {
		t.Fatalf("recorded %+v, want the finished model load", got)
	}
}

// While a model load runs, the Build tree's line says what the tool printed last and a click on
// it shows the load's session in the Run window. Stopping the session ends the tool, ends the
// load as stopped without recording a failure or loading again by itself, and leaves a line
// that is no warning; the session's rerun loads the model again in the same tab.
func TestBuildModelLoadTheUserStopsEndsStoppedAndRerunsInItsTab(t *testing.T) {
	h, plugins, p := openBuildCommand(t)
	writeBuildCommandMarker(t, p.root, "download-hang")
	id := p.build.instances[0].ID
	h.app.loadBuildModel(p, 0)
	session := p.buildSyncSession(id)
	if session == nil {
		t.Fatal("the load opened no session")
	}
	// The harness waits for every load when it closes; a failed assertion still ends this one.
	t.Cleanup(func() { h.app.stopRun(p, session) })
	awaitStateWithin(t, h, buildSyncWait, "the tool's download line", func() bool { return session.sync.latest == buildCommandDownloadLine })
	if row := buildModelNote(t, h, p); !row.loading || row.detail != buildCommandDownloadLine || row.sync != session.id {
		t.Fatalf("the loading line = loading %v, detail %q, session %q; want the last line and session %q", row.loading, row.detail, row.sync, session.id)
	}

	// The load runs, so the window is painted frame by frame: settling would wait for it. The
	// window opens through a post, which wakes the driver to paint it.
	p.build.view = ""
	h.app.post(func(a *App) { a.reduceChrome(core.SetChromeOpen(itemBuild, true)) })
	// The tool window is narrow, so the line may end cut short.
	var detail gfx.Rect
	awaitStateWithin(t, h, buildSyncWait, "the Build window to show the load's last line", func() bool {
		for _, label := range h.driver.Snapshot().Labels {
			if strings.HasPrefix(label.Value, "go: downloading") {
				detail = label.Bounds
				return true
			}
		}
		return false
	})
	point := center(detail)
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, buildSyncWait, "the click to show the session", func() bool {
		return p.build.view == session.id && h.app.chrome.isOpen(h.app.chrome.index[itemRun])
	})

	h.app.stopRun(p, session)
	if session.sync.latest != h.app.text.Build.Stopping {
		t.Fatalf("a stopping session shows %q", session.sync.latest)
	}
	awaitStateWithin(t, h, buildSyncWait, "the stopped load to end", func() bool { return !p.build.instances[0].modelLoading })
	stopped := i18n.Shared(h.app.language(), "desktop.build.modelStopped")
	instance := &p.build.instances[0]
	if session.outcome != runStopped || session.summary != stopped || session.running {
		t.Fatalf("the stopped session = outcome %v, summary %q, running %v", session.outcome, session.summary, session.running)
	}
	if !instance.modelStopped || instance.modelError != stopped || instance.modelLoaded {
		t.Fatalf("the stopped model = stopped %v, error %q, loaded %v", instance.modelStopped, instance.modelError, instance.modelLoaded)
	}
	plugins.none(t)
	h.app.loadOpenBuildModels(p)
	if instance.modelLoading {
		t.Fatal("a load the user stopped started again by itself")
	}
	if row := buildModelNote(t, h, p); row.label != stopped || row.warning || !row.model || row.sync != session.id {
		t.Fatalf("the stopped line = %q, warning %v, model %v, session %q", row.label, row.warning, row.model, row.sync)
	}

	writeBuildCommandMarker(t, p.root, "fail")
	session.restart(h.app, p)
	rerun := p.buildSyncSession(id)
	if rerun == session || rerun == nil || !rerun.running || buildSyncSessions(p) != 1 {
		t.Fatalf("the rerun = %+v among %d sync sessions, want a new running session in the stopped one's tab", rerun, buildSyncSessions(p))
	}
	awaitStateWithin(t, h, buildSyncWait, "the rerun to end", func() bool { return !p.build.instances[0].modelLoading })
	if rerun.outcome != runFailed || rerun.summary == "" || instance.modelStopped {
		t.Fatalf("the failed rerun = outcome %v, summary %q, model stopped %v", rerun.outcome, rerun.summary, instance.modelStopped)
	}
	if row := buildModelNote(t, h, p); !row.warning || row.sync != rerun.id {
		t.Fatalf("the failed line = warning %v, session %q; want a warning that shows %q", row.warning, row.sync, rerun.id)
	}
	if got := plugins.next(t, "the failed rerun"); got.Outcome != "failed" || got.Stage != core.StageExit {
		t.Fatalf("recorded %+v, want the rerun failed at its exit", got)
	}
}
