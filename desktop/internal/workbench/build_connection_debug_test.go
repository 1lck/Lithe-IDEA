package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fixtureServicePortVariable carries the debug port from the fixture provider's run plan to the
// fixture service process (TestFixtureServiceRunner).
const fixtureServicePortVariable = "LITHE_FIXTURE_SERVICE_PORT"

// fixtureServiceLifetime bounds a fixture service the host never stops, so a broken test cannot
// leave it listening.
const fixtureServiceLifetime = 2 * time.Minute

// fixtureServiceAliveVariable names a file the fixture service writes once it has run for
// fixtureServiceAliveAfter, which proves the host let it run that long.
const (
	fixtureServiceAliveVariable = "LITHE_FIXTURE_SERVICE_ALIVE"
	fixtureServiceAliveAfter    = 6 * time.Second
)

// TestFixtureServiceRunner is the fixture service a provider run starts for debugging: the
// copied test binary, found on PATH as fixture-service. It listens on the debug port the host
// chose, as a runtime suspended until a debugger attaches does, and accepts and closes
// connections until the host stops it.
func TestFixtureServiceRunner(t *testing.T) {
	port := os.Getenv(fixtureServicePortVariable)
	if port == "" {
		t.Skip("not a fixture service run")
	}
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", port))
	if err != nil {
		os.Exit(2)
	}
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			_ = connection.Close()
		}
	}()
	if alive := os.Getenv(fixtureServiceAliveVariable); alive != "" {
		// The parent waits on the file this writes, never on a timer.
		// test-stability: allow(go-real-sleep) reason: whether the host lets a service outlive its preparation bound only shows after that much time has passed.
		time.Sleep(fixtureServiceAliveAfter)
		if err := os.WriteFile(alive, []byte("alive\n"), 0o600); err != nil {
			os.Exit(3)
		}
	}
	// test-stability: allow(go-real-sleep) reason: this is the service process itself, which serves until the host stops it; the bound only ends a service a broken test never stopped.
	time.Sleep(fixtureServiceLifetime)
	os.Exit(0)
}

// providerServiceDebugManifest is the provider fixture with a service run of the targets tagged
// app that debugs through any enabled adapter of the public type fixture-attach.
var providerServiceDebugManifest = strings.Replace(providerTestsManifest, `"model": {"source": "provider"},`,
	`"model": {"source": "provider"},
    "run": [{"id": "service", "source": "provider", "fromTargets": {"tags": ["app"]}, "execution": "service", "debug": {"configurationType": "fixture-attach"}}],`, 1)

// registryAttachManifest is an attach adapter of another plugin that answers to the type
// fixture-attach and binds a connection target.
func registryAttachManifest(id string) string {
	manifest := strings.Replace(debugAttachManifest, `"dev.lithe.test.debug-attach"`, `"`+id+`"`, 1)
	return strings.Replace(manifest, `"requests": ["attach"],`, `"requests": ["attach"],
    "configurationTypes": ["fixture-attach"],`, 1)
}

// connectionDebugHarness installs the provider plugin and the given adapter plugins (ID to
// manifest), each with the copied test binary as its program, and puts the fixture build tool
// and the fixture service on PATH.
func connectionDebugHarness(t *testing.T, adapters map[string]string) *harness {
	t.Helper()
	return connectionDebugHarnessWithProvider(t, providerServiceDebugManifest, adapters)
}

func connectionDebugHarnessWithProvider(t *testing.T, providerManifest string, adapters map[string]string) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	install := func(id, manifest, program string) {
		installed := filepath.Join(pluginRoot, id, "1.0.0")
		if err := os.MkdirAll(installed, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(manifest), 0o600); err != nil {
			t.Fatal(err)
		}
		copyTestBinary(t, filepath.Join(installed, program))
		if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
	}
	install("dev.lithe.test.provider-tests", providerManifest, "provider")
	for id, manifest := range adapters {
		if runtime.GOOS == "windows" {
			manifest = strings.ReplaceAll(manifest, `"path": "adapter"`, `"path": "adapter.exe"`)
		}
		install(id, manifest, debugFixtureProgramName())
	}
	// The host resolves the provider's build tool before it starts the provider, which never
	// runs it; the run plan names the fixture service as a command on PATH.
	bin := t.TempDir()
	tool, service := filepath.Join(bin, "fixture-tool"), filepath.Join(bin, "fixture-service")
	if runtime.GOOS == "windows" {
		tool, service = tool+".exe", service+".exe"
		t.Setenv("PATHEXT", ".EXE")
	}
	if err := writeFakeExecutable(tool); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, service)
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	return newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
		// The provider is a copy of this large instrumented test binary: under load its start
		// can exceed Core's 10s default. The bound stays finite.
		PluginInitializeTimeout: 60 * time.Second,
	})
}

// openServiceDebugProject opens the provider fixture workspace with its service target and
// returns the project once its run configurations list the service.
func openServiceDebugProject(t *testing.T, h *harness) (*project, string) {
	t.Helper()
	root := t.TempDir()
	// debug.marker lets the fixture adapter serve DAP in this workspace (TestDebugAdapterRunner).
	for _, marker := range []string{"fixture.marker", "discovery.marker", "service.marker", "debug.marker"} {
		if err := os.WriteFile(filepath.Join(root, marker), []byte("fixture\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "lib"), 0o700); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.loadTitleRunConfigs(p) })
	awaitStateWithin(t, h, time.Minute, "the service configuration", func() bool {
		return len(p.build.instances) == 1 && p.build.instances[0].modelLoaded && p.runConfigsSettled() && len(p.runConfigs.list) > 0
	})
	configuration := p.runConfigs.list[0]
	if len(p.runConfigs.list) != 1 || configuration.Execution != "service" {
		t.Fatalf("run configurations = %+v, want the one service", p.runConfigs.list)
	}
	return p, configuration.ID
}

// preparedDebug is the launchOptions.debug the fixture provider received.
type preparedDebug struct {
	Execution  string `json:"execution"`
	Entrypoint string `json:"entrypoint"`
	Debug      *struct {
		AdapterID         string `json:"adapterID"`
		ConfigurationType string `json:"configurationType"`
		Target            struct {
			Kind string `json:"kind"`
			Host string `json:"host"`
			Port int    `json:"port"`
		} `json:"target"`
	} `json:"debug"`
}

// readPreparedRun reads what the fixture provider was asked to prepare.
func readPreparedRun(t *testing.T, root string) preparedDebug {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, "prepare-run.json"))
	if err != nil {
		t.Fatal(err)
	}
	var params struct {
		LaunchOptions preparedDebug `json:"launchOptions"`
	}
	if err := json.Unmarshal(data, &params); err != nil {
		t.Fatal(err)
	}
	return params.LaunchOptions
}

// Debug on a service configuration whose run names a public debug type starts the service
// through its provider with a host-chosen loopback port, then attaches the one enabled adapter
// of that type, which another plugin installs. Stopping the debug session stops the service.
// The host used to read only same-plugin adapters, so it called the configuration not
// debuggable.
func TestTitleDebugAttachesTheRegisteredAdapterToAServiceRun(t *testing.T) {
	h := connectionDebugHarness(t, map[string]string{"dev.lithe.test.registry-attach": registryAttachManifest("dev.lithe.test.registry-attach")})
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	p, id := openServiceDebugProject(t, h)
	t.Cleanup(func() {
		if !t.Failed() {
			return
		}
		console := ""
		if runs := p.build.runs; len(runs) > 0 {
			console = runs[len(runs)-1].output.all()
		}
		t.Logf("notice %q, build status %q, debug failure %q, run console:\n%s", lastNotice(h), p.build.status, p.debug.failure, console)
	})

	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, id)
		a.titleDebug(p)
	})
	configuration := awaitValueWithin(t, h, time.Minute, gate.configurations, "the attach to the service")
	prepared := readPreparedRun(t, p.root)
	if prepared.Execution != "service" || prepared.Debug == nil {
		t.Fatalf("the provider prepared %+v, want a service run with a debug target", prepared)
	}
	debug := prepared.Debug
	if debug.AdapterID != "dev.lithe.test.registry-attach/attach" || debug.ConfigurationType != "fixture-attach" ||
		debug.Target.Kind != "connection" || debug.Target.Host != "127.0.0.1" || debug.Target.Port <= 0 {
		t.Fatalf("launchOptions.debug = %+v", *debug)
	}
	if configuration.Request != "attach" || configuration.Arguments["hostName"] != "127.0.0.1" || !sameDebugPort(configuration.Arguments["port"], debug.Target.Port) {
		t.Fatalf("attach configuration = %+v, want the service's port %d", configuration, debug.Target.Port)
	}
	session := p.debug.activeSession()
	if session == nil || session.adapter.PluginID != "dev.lithe.test.registry-attach" {
		t.Fatalf("debug session = %+v, want the registered adapter's", session)
	}
	if !p.build.active() {
		t.Fatal("the service is not running while it is debugged")
	}

	// Stop in the Debug window ends the service it attached to.
	h.app.post(func(a *App) { a.stopDebugByUser(p) })
	awaitStateWithin(t, h, time.Minute, "the stopped service", func() bool { return !p.build.active() && p.debug.activeSession() == nil })
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(debug.Target.Port)))
	if err != nil {
		t.Fatalf("the service still holds its debug port after Stop: %v", err)
	}
	_ = listener.Close()
}

func TestCurrentFileDebugSavesAndAttachesToTheDiscoveredEntrypoint(t *testing.T) {
	const adapterID = "dev.lithe.test.registry-attach"
	h := connectionDebugHarnessWithProvider(t, debugEntrypointsManifest(), map[string]string{adapterID: registryAttachManifest(adapterID)})
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	root := entrypointWorkspace(t)
	writeFixture(t, root, map[string]string{"debug.marker": "fixture\n"})
	h.open(root)
	p := h.app.project
	openSource(t, h, p, filepath.Join(root, "src", "Main.java"))
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleDebug(p)
	})
	configuration := awaitValueWithin(t, h, time.Minute, gate.configurations, "the attach to the discovered entrypoint")
	prepared := readPreparedRun(t, root)
	if prepared.Execution != "application" || prepared.Entrypoint != "example.Main" || prepared.Debug == nil {
		t.Fatalf("the provider prepared %+v, want the application entrypoint with a debug target", prepared)
	}
	if configuration.Request != "attach" || !sameDebugPort(configuration.Arguments["port"], prepared.Debug.Target.Port) {
		t.Fatalf("attach configuration = %+v, want the entrypoint's port %d", configuration, prepared.Debug.Target.Port)
	}
	saved := p.titleConfiguration()
	if saved == nil || saved.Name != "Main" || len(p.runConfigs.list) != 1 {
		t.Fatalf("selected configuration = %+v, configurations = %+v", saved, p.runConfigs.list)
	}
	h.app.post(func(a *App) { a.stopDebugByUser(p) })
	awaitStateWithin(t, h, time.Minute, "the stopped entrypoint", func() bool { return !p.build.active() && p.debug.activeSession() == nil })
}

func debugEntrypointsManifest() string {
	manifest := strings.Replace(providerEntrypointsManifest, `"buildSystems": 0`, `"buildSystems": 2`, 1)
	return strings.Replace(manifest, `"entrypoints": true`, `"entrypoints": true, "debug": {"configurationType": "fixture-attach"}`, 1)
}

type entrypointDiscoveryKernel struct {
	Kernel
	discover func(context.Context, core.BuildPlanRequest) error
}

func (k entrypointDiscoveryKernel) PlanBuildRunEntrypoints(ctx context.Context, manifest json.RawMessage, system string, request core.BuildPlanRequest) (core.BuildPlan, error) {
	if err := k.discover(ctx, request); err != nil {
		return core.BuildPlan{}, err
	}
	return k.Kernel.PlanBuildRunEntrypoints(ctx, manifest, system, request)
}

func TestCurrentFileDebugFallsBackWhenProviderDiscoveryFails(t *testing.T) {
	h := connectionDebugHarnessWithProvider(t, debugEntrypointsManifest(), nil)
	failure := errors.New("fixture entrypoint discovery failed")
	discovering := make(chan struct{}, 1)
	finishDiscovery := make(chan struct{})
	h.app.kernel = entrypointDiscoveryKernel{
		Kernel: h.app.kernel,
		discover: func(ctx context.Context, _ core.BuildPlanRequest) error {
			discovering <- struct{}{}
			select {
			case <-finishDiscovery:
				return failure
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	}
	root := entrypointWorkspace(t)
	h.open(root)
	p := h.app.project
	openSource(t, h, p, filepath.Join(root, "src", "Main.java"))
	d := p.selectedDocument(p.docs.group)
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleDebug(p)
	})
	awaitValueWithin(t, h, 15*time.Second, discovering, "the provider discovery request")
	h.app.post(func(a *App) {
		d.actions = []pluginservice.EditorAction{{
			Title: "Debug editor entry", Icon: "debug",
			Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1},
		}}
		close(finishDiscovery)
	})
	want := i18n.SharedFormat(h.app.language(), "desktop.editorActions.starting", map[string]string{"label": "Debug editor entry"})
	awaitStateWithin(t, h, 15*time.Second, "the editor debug action", func() bool {
		notices := noticeTexts(h.app)
		if slices.Contains(notices, failure.Error()) {
			t.Fatalf("provider failure blocked editor debug: %v", notices)
		}
		return slices.Contains(notices, want)
	})
}

func TestCurrentFileDebugSavesEditsBeforeDiscoveringAnEntrypoint(t *testing.T) {
	h := connectionDebugHarnessWithProvider(t, debugEntrypointsManifest(), nil)
	const modified = "package example;\n\npublic final class Main {}\n"
	sourceAtDiscovery := make(chan string, 1)
	h.app.kernel = entrypointDiscoveryKernel{
		Kernel: h.app.kernel,
		discover: func(_ context.Context, request core.BuildPlanRequest) error {
			data, err := os.ReadFile(filepath.Join(request.WorkspaceRoot, filepath.FromSlash(request.File)))
			if err != nil {
				return err
			}
			sourceAtDiscovery <- string(data)
			return errors.New("fixture stops after reading the source")
		},
	}
	root := entrypointWorkspace(t)
	h.open(root)
	p := h.app.project
	openSource(t, h, p, filepath.Join(root, "src", "Main.java"))
	d := p.selectedDocument(p.docs.group)
	data, _ := d.view.Text()
	if err := d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{End: len(data)}, Text: modified}}); err != nil {
		t.Fatal(err)
	}
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleDebug(p)
	})
	if got := awaitValueWithin(t, h, 15*time.Second, sourceAtDiscovery, "the source read by the provider"); got != modified {
		t.Fatalf("provider read stale source: %q", got)
	}
}

// sameDebugPort reports whether a DAP argument decoded from JSON is port.
func sameDebugPort(value any, port int) bool {
	switch number := value.(type) {
	case float64:
		return number == float64(port)
	case int64:
		return number == int64(port)
	case uint64:
		return number == uint64(port)
	}
	return false
}

// Without an enabled adapter of the run's type, or with two of them, Debug refuses before the
// provider prepares anything: nothing would attach to the suspended service, and choosing one of
// two would be a guess.
func TestServiceDebugRefusesAMissingOrAmbiguousAdapterBeforePreparing(t *testing.T) {
	for _, tc := range []struct {
		name     string
		adapters map[string]string
		notice   func(lang i18n.Language) string
	}{
		{
			name:     "missing",
			adapters: map[string]string{"dev.lithe.test.debug-attach": debugAttachManifest},
			notice: func(lang i18n.Language) string {
				return i18n.SharedFormat(lang, "desktop.build.noConnectionDebugAdapter", map[string]string{"type": "fixture-attach"})
			},
		},
		{
			name: "ambiguous",
			adapters: map[string]string{
				"dev.lithe.test.registry-attach":  registryAttachManifest("dev.lithe.test.registry-attach"),
				"dev.lithe.test.registry-attach2": registryAttachManifest("dev.lithe.test.registry-attach2"),
			},
			notice: func(lang i18n.Language) string {
				return i18n.SharedFormat(lang, "desktop.build.ambiguousConnectionDebugAdapter", map[string]string{"type": "fixture-attach", "adapters": "Attach DAP, Attach DAP"})
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := connectionDebugHarness(t, tc.adapters)
			p, id := openServiceDebugProject(t, h)
			h.app.post(func(a *App) {
				a.chooseTitleConfiguration(p, id)
				a.titleDebug(p)
			})
			want := tc.notice(h.app.language())
			if want == "" || strings.Contains(want, "desktop.build.") {
				t.Fatalf("the refusal has no message: %q", want)
			}
			awaitStateWithin(t, h, time.Minute, "the refusal", func() bool { return lastNotice(h) == want })
			if p.build.active() || p.debug.activeSession() != nil {
				t.Fatalf("a refused debug started something: operation %v, session %v", p.build.latest(), p.debug.activeSession())
			}
			if _, err := os.Stat(filepath.Join(p.root, "prepare-run.json")); !os.IsNotExist(err) {
				t.Fatalf("the provider prepared a run that nothing could debug: %v", err)
			}
		})
	}
}

// The project reads the debug adapters again when the plugins change, so Debug offers an
// adapter the user just enabled and no longer offers one just disabled. The list used to be
// read once per project, so a plugin enabled after the first Debug stayed unavailable until the
// project was opened again.
func TestDebugAdaptersAreReadAgainWhenPluginsChange(t *testing.T) {
	const id = "dev.lithe.test.registry-attach"
	h := connectionDebugHarness(t, map[string]string{id: registryAttachManifest(id)})
	h.open(t.TempDir())
	p := h.app.project
	h.app.post(func(a *App) { a.loadDebugAdapters(p) })
	awaitStateWithin(t, h, time.Minute, "the installed adapters", func() bool { return p.debug.loaded && !p.debug.loading })
	if len(p.debug.adapters) != 1 || p.debug.adapters[0].PluginID != id {
		t.Fatalf("adapters = %+v, want the registry adapter", p.debug.adapters)
	}

	h.app.post(func(a *App) { a.setPluginEnabled(id, false) })
	awaitStateWithin(t, h, time.Minute, "the adapters without the disabled plugin", func() bool {
		return p.debug.loaded && !p.debug.loading && len(p.debug.adapters) == 0
	})

	h.app.post(func(a *App) { a.setPluginEnabled(id, true) })
	awaitStateWithin(t, h, time.Minute, "the adapters with the enabled plugin", func() bool {
		return p.debug.loaded && !p.debug.loading && len(p.debug.adapters) == 1
	})
	if p.debug.selectedAdapter != 0 {
		t.Fatalf("selected adapter %d of %d", p.debug.selectedAdapter, len(p.debug.adapters))
	}
}

// A run's process outlives the bound on its preparation: a service runs until it exits, the
// user stops it or the project closes. The host used to start the process under the request's
// 30-minute deadline, so every service that ran that long was killed. The test shortens the
// bound to 5 seconds and checks that the service still runs after 6.
func TestServiceRunOutlivesItsPreparationBound(t *testing.T) {
	previous := runPreparationTimeout
	runPreparationTimeout = 5 * time.Second
	t.Cleanup(func() { runPreparationTimeout = previous })
	alive := filepath.Join(t.TempDir(), "alive")
	t.Setenv(fixtureServiceAliveVariable, alive)
	h := connectionDebugHarness(t, nil)
	p, id := openServiceDebugProject(t, h)

	started := make(chan *buildOperation, 1)
	h.app.post(func(a *App) {
		op, err := a.startRunConfiguration(p, id)
		if err != nil {
			t.Errorf("start the service: %v", err)
		}
		started <- op
	})
	op := awaitValueWithin(t, h, 30*time.Second, started, "the service run")
	if op == nil {
		t.FailNow()
	}
	awaitStateWithin(t, h, time.Minute, "the service to outlive its preparation bound or end", func() bool {
		_, err := os.Stat(alive)
		return err == nil || !op.session.running
	})
	if _, err := os.Stat(alive); err != nil {
		t.Fatalf("the service ended before it ran for %s: status %q, console:\n%s", fixtureServiceAliveAfter, p.build.status, op.session.output.all())
	}
	if !p.build.owns(op) {
		t.Fatal("the service is not running after it outlived its preparation bound")
	}
	h.app.post(func(a *App) { a.stopOperation(p, op) })
	awaitStateWithin(t, h, time.Minute, "the stopped service", func() bool { return !p.build.active() })
}
