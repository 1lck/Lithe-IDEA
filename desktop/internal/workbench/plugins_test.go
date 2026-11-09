package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

func TestCompactProgramFitsOneLine(t *testing.T) {
	program := json.RawMessage("{\n  \"kind\": \"runtime\",\n  \"command\": \"java\"\n}")
	if got := compactProgram(program); got != `{"kind":"runtime","command":"java"}` {
		t.Fatalf("compact = %q", got)
	}
	// Invalid JSON is shown as it arrived rather than dropped: the review exists to
	// show exactly what the package declared.
	if got := compactProgram(json.RawMessage("{broken")); got != "{broken" {
		t.Fatalf("compact = %q", got)
	}
}

func TestInstallPluginWithoutStackDoesNothing(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.installPlugin(core.MarketplacePlugin{ID: "example"})
	if h.app.pluginInstall.busy || h.app.pluginInstall.open {
		t.Fatalf("state = %+v", h.app.pluginInstall)
	}
	if h.app.pluginInstall.generation != 0 {
		t.Fatalf("generation = %d", h.app.pluginInstall.generation)
	}
}

func TestFinishPluginInstallOpensTheReview(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.pluginInstall.generation = 7
	h.app.pluginInstall.busy = true
	plan := plugininstall.Plan{ID: "example", Version: "1.0.0"}
	h.app.finishPluginInstall(7, plan, nil)
	if !h.app.pluginInstall.open {
		t.Fatal("the review did not open")
	}
	if h.app.pluginInstall.busy {
		t.Fatal("the install is still marked busy")
	}
	if h.app.pluginInstall.plan.Version != "1.0.0" {
		t.Fatalf("plan = %+v", h.app.pluginInstall.plan)
	}
}

func TestFinishPluginInstallDropsAStaleResult(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.pluginInstall.generation = 7
	h.app.pluginInstall.busy = true
	// A result from the install the user replaced.
	h.app.finishPluginInstall(6, plugininstall.Plan{ID: "old", Version: "0.9.0"}, nil)
	if h.app.pluginInstall.open {
		t.Fatal("a stale result opened the review")
	}
	if h.app.pluginInstall.plan.Version != "" {
		t.Fatalf("plan = %+v", h.app.pluginInstall.plan)
	}
	if !h.app.pluginInstall.busy {
		t.Fatal("a stale result cleared the current install's busy state")
	}
}

func TestFinishPluginInstallReportsFailure(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.pluginInstall.generation = 1
	h.app.pluginInstall.busy = true
	h.app.finishPluginInstall(1, plugininstall.Plan{}, plugininstall.ErrArchiveDigest)
	if h.app.pluginInstall.open {
		t.Fatal("a failed install opened the review")
	}
	if h.app.pluginInstall.busy {
		t.Fatal("the install is still marked busy")
	}
	if h.app.notice == "" {
		t.Fatal("a failed install said nothing")
	}
}

func TestCancelPluginInstallClearsTheState(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.pluginInstall.open = true
	h.app.pluginInstall.generation = 3
	h.app.pluginInstall.plan = plugininstall.Plan{ID: "example", Version: "1.0.0"}
	h.app.cancelPluginInstall()
	if h.app.pluginInstall.open || h.app.pluginInstall.plan.Version != "" {
		t.Fatalf("state = %+v", h.app.pluginInstall)
	}
	if h.app.pluginInstall.generation != 4 {
		t.Fatalf("generation = %d", h.app.pluginInstall.generation)
	}
}

func TestPluginStateIsReadFromTheCache(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if state := h.app.pluginState.Load(); state != nil {
		t.Fatalf("state = %v", state)
	}
	states := map[string]settingswindow.PluginState{"example": {Installed: true, Version: "1.0.0", Enabled: true}}
	h.app.pluginState.Store(&states)
	loaded := h.app.pluginState.Load()
	if loaded == nil || (*loaded)["example"].Version != "1.0.0" {
		t.Fatalf("loaded = %v", loaded)
	}
}
