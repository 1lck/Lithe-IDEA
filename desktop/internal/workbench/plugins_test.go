package workbench

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
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

// Removing an adapter's package must wait for the native process, not just the
// plugin backend: on Windows the executable cannot be removed while it runs.
func TestUninstallWaitsForTheDebugAdapter(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "the adapter's ready event", func() bool { return p.debug.state == "paused" })
	h.app.refreshPluginState()
	h.settle()
	h.app.uninstallPlugin(session.adapter.PluginID)
	awaitStateWithin(t, h, debugAdapterExitWait, "the adapter package's removal", func() bool {
		_, err := os.Stat(session.adapter.Directory)
		return errors.Is(err, os.ErrNotExist)
	})
	select {
	case <-session.exitObserved:
	default:
		t.Fatal("the package was removed before its adapter exited")
	}
	if p.debug.hasSession(session) {
		t.Fatal("the uninstalled adapter's session is still in the panel")
	}
}

type uninstallOrderKernel struct {
	*testKernel
	directory string
	destroyed chan bool
}

func (k *uninstallOrderKernel) DestroyPluginBackend(ctx context.Context, id string) error {
	_, statErr := os.Stat(k.directory)
	err := k.Client.DestroyPluginBackend(ctx, id)
	if err == nil {
		k.destroyed <- statErr == nil
	}
	return err
}

func TestUninstallStopsProviderSessionsBeforeDeletingFiles(t *testing.T) {
	for _, role := range []string{"build", "vcs"} {
		t.Run(role, func(t *testing.T) {
			manifest := providerTestsManifest
			if role == "vcs" {
				manifest = vcsFixtureManifest
			}
			kernel := &uninstallOrderKernel{testKernel: &testKernel{Client: core.NewClient()}, destroyed: make(chan bool, 16)}
			h := providerTestsHarnessWith(t, manifest, kernel)
			const id = "dev.lithe.test.provider-tests"
			directory := filepath.Join(h.app.plugins.Root, id, "1.0.0")
			kernel.directory = directory
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, "fixture.marker"), nil, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(filepath.Join(root, ".fakevcs"), 0o700); err != nil {
				t.Fatal(err)
			}
			h.open(root)
			p := h.app.project
			var client *buildprovider.Client
			runtime := p.vcs.runtime()
			h.app.background(p, 30*time.Second, func(ctx context.Context) func(*App) {
				uri, err := h.app.kernel.PluginDocumentURI(ctx, root, "auto")
				var started *buildprovider.Client
				if err == nil && role == "build" {
					started, err = h.app.buildProvider(ctx, p, buildInstance{
						BuildInstance: core.BuildInstance{BuildSystemID: "fixture-provider-tests"},
						PluginID:      id, Version: "1.0.0", PackageDirectory: directory, Manifest: json.RawMessage(manifest),
					})
				} else if err == nil {
					started, err = runtime.session(ctx, h.app.plugins.Backend, h.app.plugins.Root, root, uri,
						vcsWindow{PluginID: id, Version: "1.0.0", Directory: directory, Manifest: json.RawMessage(manifest), Vcs: "fakevcs"}, core.PluginSettingsState{})
				}
				return func(*App) {
					if err != nil {
						t.Fatalf("start %s: %v", role, err)
					}
					client = started
				}
			})
			h.settle()
			if client == nil {
				t.Fatal("the provider did not start")
			}
			h.app.refreshPluginState()
			h.settle()
			h.app.uninstallPlugin(id)
			awaitStateWithin(t, h, 30*time.Second, "the provider package's removal", func() bool {
				_, err := os.Stat(directory)
				return errors.Is(err, os.ErrNotExist)
			})
			if !client.Closed() {
				t.Fatal("the provider was still live when its files were removed")
			}
			h.settle()
			select {
			case present := <-kernel.destroyed:
				if !present {
					t.Fatal("the provider process was destroyed after its package was removed")
				}
			default:
				t.Fatal("the provider process was never destroyed")
			}
			state := filepath.Join(h.app.plugins.Root, pluginpkg.StateDirectory, id)
			if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("the provider's state survived: %v", err)
			}
			if role == "vcs" {
				// Even a refresh already queued before uninstall must retain the
				// launch barrier when it replaces the VCS runtime.
				h.app.invalidateVcs(p)
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				_, err := p.vcs.runtime().session(ctx, h.app.plugins.Backend, h.app.plugins.Root, root, "",
					vcsWindow{PluginID: id, Version: "1.0.0"}, core.PluginSettingsState{})
				if !errors.Is(err, buildprovider.ErrClosed) {
					t.Fatalf("catalog refresh reopened a removed plugin: %v", err)
				}
				if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("a stale VCS request recreated state: %v", err)
				}
			}
		})
	}
}

// Hold a native start inside Core's launch plan after it has created its state
// directory. Uninstall must cancel it and wait even if that call returns late.
type uninstallStartKernel struct {
	*testKernel
	entered, cancelled, release chan struct{}
	once                        sync.Once
}

func (k *uninstallStartKernel) PlanPluginBuildProvider(ctx context.Context, _ json.RawMessage, _ string, _ core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	k.once.Do(func() { close(k.entered) })
	select {
	case <-ctx.Done():
		close(k.cancelled)
	case <-time.After(30 * time.Second):
		return core.PluginBackendPlan{}, errors.New("the start was never cancelled")
	}
	select {
	case <-k.release:
		return core.PluginBackendPlan{}, ctx.Err()
	case <-time.After(30 * time.Second):
		return core.PluginBackendPlan{}, errors.New("the test never released the start")
	}
}

func TestUninstallWaitsForAProviderStillStartingInHiddenTab(t *testing.T) {
	kernel := &uninstallStartKernel{testKernel: &testKernel{Client: core.NewClient()}, entered: make(chan struct{}), cancelled: make(chan struct{}), release: make(chan struct{})}
	h := providerTestsHarness(t, kernel)
	hidden := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.OpenAnother(kernel, h.app.store, h.app.plugins.Root)
	if err != nil {
		t.Fatal(err)
	}
	hidden.app.plugins = service
	hidden.open(t.TempDir())
	h.app.sessions = &windowSessions{list: []*App{h.app, hidden.app}, active: h.app}
	h.app.refreshPluginState()
	h.settle()
	const id = "dev.lithe.test.provider-tests"
	directory := filepath.Join(service.Root, id, "1.0.0")
	var release sync.Once
	t.Cleanup(func() { release.Do(func() { close(kernel.release) }) })
	hidden.app.background(hidden.app.project, 30*time.Second, func(ctx context.Context) func(*App) {
		_, err := hidden.app.buildProvider(ctx, hidden.app.project, buildInstance{
			BuildInstance: core.BuildInstance{BuildSystemID: "fixture-provider-tests"}, PluginID: id,
			Version: "1.0.0", PackageDirectory: directory, Manifest: json.RawMessage(providerTestsManifest),
		})
		return func(*App) {
			if !errors.Is(err, context.Canceled) {
				t.Errorf("the cancelled start returned %v", err)
			}
		}
	})
	select {
	case <-kernel.entered:
	case <-time.After(30 * time.Second):
		t.Fatal("the provider never reached its launch plan")
	}
	h.app.uninstallPlugin(id)
	select {
	case <-kernel.cancelled:
	case <-time.After(30 * time.Second):
		t.Fatal("uninstall did not cancel the hidden tab's start")
	}
	if _, err := os.Stat(directory); err != nil {
		t.Fatalf("uninstall removed the package while its start was still in flight: %v", err)
	}
	release.Do(func() { close(kernel.release) })
	h.settle()
	hidden.settle()
	for _, gone := range []string{directory, filepath.Join(service.Root, pluginpkg.StateDirectory, id)} {
		if _, err := os.Stat(gone); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("the cancelled start left %s: %v", gone, err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err = hidden.app.buildProvider(ctx, hidden.app.project, buildInstance{PluginID: id})
	if !errors.Is(err, buildprovider.ErrClosed) {
		t.Fatalf("a stale request could start the uninstalled plugin: %v", err)
	}
}

func TestEnableReopensVcsAfterCatalogRefresh(t *testing.T) {
	h := providerTestsHarnessWith(t, vcsFixtureManifest)
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".fakevcs"), 0o700); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	const id = "dev.lithe.test.provider-tests"
	stop := p.vcs.runtime().detachPlugin(id)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := stop(ctx); err != nil {
		t.Fatal(err)
	}
	h.app.invalidateVcs(p)
	h.app.setPluginEnabled(id, true)
	h.settle()
	sessions := p.vcs.runtime()
	h.app.background(p, 30*time.Second, func(ctx context.Context) func(*App) {
		uri, err := h.app.kernel.PluginDocumentURI(ctx, root, "auto")
		if err == nil {
			_, err = sessions.session(ctx, h.app.plugins.Backend, h.app.plugins.Root, root, uri,
				vcsWindow{PluginID: id, Version: "1.0.0", Directory: filepath.Join(h.app.plugins.Root, id, "1.0.0"), Manifest: json.RawMessage(vcsFixtureManifest), Vcs: "fakevcs"}, core.PluginSettingsState{})
		}
		return func(*App) {
			if err != nil {
				t.Errorf("the enabled VCS provider could not start after a catalog refresh: %v", err)
			}
		}
	})
	h.settle()
}
