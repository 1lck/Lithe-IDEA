package workbench

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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

// installablePluginManifest is a plugin without programs, so installing it from
// disk needs no publisher and starts nothing.
const installablePluginManifest = `{
  "schemaVersion": 0,
  "id": "io.github.example.output-links",
  "displayName": "Output Links",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"outputLinkMatchers": 0},
  "vendor": {"id": "io.github.example", "displayName": "Example", "signatureRequirement": "none"},
  "permissions": [],
  "activationEvents": [],
  "languages": [],
  "outputLinkMatchers": [{"id": "frame", "pattern": "at (?P<path>[\\w/.]+\\.txt):(?P<line>\\d+)", "scope": "run"}]
}`

// A confirmed installation works at once, and uninstalling leaves nothing of the
// plugin below the plugin root: not its package, not the state its programs
// wrote.
func TestConfirmedInstallIsEnabledAndUninstallRemovesItsState(t *testing.T) {
	const id = "io.github.example.output-links"
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pluginRoot := t.TempDir()
	service, err := pluginservice.Open(core.NewClient(), h.store, pluginRoot)
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	archive := filepath.Join(t.TempDir(), "output-links-1.0.0.zip")
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entry, err := writer.Create(id + "/plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(installablePluginManifest)); err != nil {
		t.Fatal(err)
	}
	if err := errors.Join(writer.Close(), file.Close()); err != nil {
		t.Fatal(err)
	}

	h.app.installPluginFromFile(archive)
	awaitStateWithin(t, h, 30*time.Second, "the install review", func() bool { return h.app.pluginInstall.open })
	h.app.confirmPluginInstall()
	state := func() settingswindow.PluginState {
		states := h.app.pluginState.Load()
		if states == nil {
			return settingswindow.PluginState{}
		}
		return (*states)[id]
	}
	awaitStateWithin(t, h, 30*time.Second, "the installed plugin", func() bool { return state().Installed })
	if !state().Enabled {
		t.Fatal("the confirmed installation is not enabled")
	}

	written := filepath.Join(pluginRoot, pluginpkg.StateDirectory, id, "1.0.0", "cache", "entry")
	if err := os.MkdirAll(filepath.Dir(written), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(written, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.uninstallPlugin(id)
	awaitStateWithin(t, h, 30*time.Second, "the uninstalled plugin", func() bool { return !state().Installed })
	for _, gone := range []string{filepath.Join(pluginRoot, id), filepath.Join(pluginRoot, pluginpkg.StateDirectory, id)} {
		if _, err := os.Stat(gone); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s survived the uninstall: %v", gone, err)
		}
	}
}
