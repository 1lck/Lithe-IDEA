package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// captureBuildDebug records the provider debug request and refuses it, so no provider starts.
type captureBuildDebug struct {
	Kernel
	requests chan core.BuildPlanRequest
}

func (k *captureBuildDebug) PlanBuildDebug(_ context.Context, _ json.RawMessage, _ string, request core.BuildPlanRequest) (core.BuildPlan, error) {
	k.requests <- request
	return core.BuildPlan{}, errors.New("captured")
}

// titleRunHarness opens root with the detected instance whose run is declared as run, and
// returns once the project's configurations are read.
func titleRunHarness(t *testing.T, kernel Kernel, run pluginservice.BuildRunDeclaration) (*harness, *project) {
	t.Helper()
	h := newHarness(t, kernel)
	h.open(runConfigRoot(t))
	p := h.app.project
	since := p.runConfigs.generation
	h.app.post(func(a *App) {
		instance := runConfigInstance("app")
		instance.System.Runs = []pluginservice.BuildRunDeclaration{run}
		setDetected(p, []buildInstance{instance})
		a.refreshRunConfigurations(p)
	})
	awaitRunConfigsAfter(t, h, p, since)
	if len(p.runConfigs.list) != 1 || p.titleConfiguration() == nil {
		t.Fatalf("configurations = %+v failure %q", p.runConfigs.list, p.runConfigs.failure)
	}
	return h, p
}

// runConfigRoot is a workspace with the project directory runConfigInstance("app") reports.
func runConfigRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

// lastNotice is the newest notice of the history, empty when there is none.
func lastNotice(h *harness) string {
	if list := h.app.notifications.list; len(list) > 0 {
		return list[0].text
	}
	return ""
}

// A press on Run before the configurations are read waits for them and then runs the one
// the title bar shows, which is the first configuration when none was chosen.
func TestTitleRunWaitsForTheConfigurationsAndRunsTheChosenOne(t *testing.T) {
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h := newHarness(t, gate)
	h.open(runConfigRoot(t))
	p := h.app.project
	h.app.post(func(a *App) {
		setDetected(p, []buildInstance{runConfigInstance("app")})
		a.refreshRunConfigurations(p)
		a.titleRun(p)
		if p.runConfigs.pending != titleActionRun {
			t.Errorf("the press did not wait for the configurations: pending %v", p.runConfigs.pending)
		}
	})
	request := awaitValueWithin(t, h, 10*time.Second, gate.requests, "the provider run request")
	if request.Run != "application" || request.Target == nil || request.Target.Name != "Main" {
		t.Fatalf("run request = %+v", request)
	}
	if p.runConfigs.pending != titleActionNone || h.app.titleRunLabel() != "Run Main" {
		t.Fatalf("pending %v label %q", p.runConfigs.pending, h.app.titleRunLabel())
	}
	if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
		t.Fatal("Run did not open the Run window")
	}
}

// Current File has nothing to run outside a configuration: Run says so and plans nothing.
func TestTitleRunOnCurrentFileExplainsAConfigurationIsNeeded(t *testing.T) {
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := titleRunHarness(t, gate, pluginservice.BuildRunDeclaration{ID: "application", Name: "Run", Tags: []string{"app"}})
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleRun(p)
	})
	h.settle()
	want := i18n.Shared(h.app.language(), "desktop.title.currentFileNotRunnable")
	if got := lastNotice(h); got != want {
		t.Fatalf("notice = %q, want %q", got, want)
	}
	if h.app.titleRunLabel() != h.app.text.Title.CurrentFile || len(gate.requests) != 0 {
		t.Fatalf("label %q, %d run requests", h.app.titleRunLabel(), len(gate.requests))
	}
}

// Debug on a configuration whose run declares no adapter names the configuration and plans
// nothing.
func TestTitleDebugWithoutADeclaredAdapterSaysSo(t *testing.T) {
	gate := &captureBuildDebug{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := titleRunHarness(t, gate, pluginservice.BuildRunDeclaration{ID: "application", Name: "Run", Tags: []string{"app"}})
	h.app.post(func(a *App) { a.titleDebug(p) })
	h.settle()
	want := i18n.SharedFormat(h.app.language(), "desktop.title.notDebuggable", map[string]string{"name": "Run Main"})
	if got := lastNotice(h); got != want {
		t.Fatalf("notice = %q, want %q", got, want)
	}
	if len(gate.requests) != 0 || p.debug.preparing {
		t.Fatalf("%d debug requests, preparing %v", len(gate.requests), p.debug.preparing)
	}
}

// Debug on a configuration whose run declares an adapter asks the provider to prepare that
// run, and a refused preparation ends the preparing state with the reason.
func TestTitleDebugPreparesTheConfigurationsRun(t *testing.T) {
	gate := &captureBuildDebug{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := titleRunHarness(t, gate, pluginservice.BuildRunDeclaration{ID: "application", Name: "Run", Tags: []string{"app"}, DebugAdapter: "native"})
	h.app.post(func(a *App) { a.titleDebug(p) })
	request := awaitValueWithin(t, h, 10*time.Second, gate.requests, "the provider debug request")
	if request.Run != "application" || request.Target == nil || request.Target.Name != "Main" || request.WorkspaceRoot != p.root {
		t.Fatalf("debug request = %+v", request)
	}
	awaitStateWithin(t, h, 10*time.Second, "the refused preparation", func() bool { return !p.debug.preparing && lastNotice(h) == "captured" })
	if !h.app.chrome.isOpen(catalogIndex[itemDebug]) {
		t.Fatal("Debug did not open the Debug window")
	}
}

// The prepared program starts under the adapter the preparation names, not the first adapter
// of the same plugin, with its workspace-relative paths joined onto the project.
func TestProviderDebugStartsTheNamedAdapter(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	named := p.debug.adapters[0]
	decoy := named
	decoy.Declaration.ID, decoy.Declaration.AdapterID = "decoy", "decoy-dap"
	p.debug.adapters = []debugAdapter{decoy, named}
	h.app.startProviderDebug(p, named.PluginID, core.BuildDebugPreparation{Adapter: named.Declaration.ID, Program: "bin/app", WorkingDirectory: "."}, nil, nil)
	session := p.debug.activeSession()
	if session == nil {
		t.Fatal("the provider did not start a debug session")
	}
	if session.adapter.Declaration.ID != named.Declaration.ID {
		t.Fatalf("session = %+v, want adapter %q", session, named.Declaration.ID)
	}
	launch := p.debug.pendingRemote.launchTarget
	if launch == nil || launch.Executable != filepath.Join(p.root, "bin", "app") || launch.WorkingDirectory != p.root || launch.Arguments == nil || launch.Environment == nil {
		t.Fatalf("launch target = %+v", launch)
	}
}

// A preparation naming an adapter its plugin does not install starts nothing and says so.
func TestProviderDebugRefusesAnAdapterThePluginDoesNotInstall(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	h.app.startProviderDebug(p, p.debug.adapters[0].PluginID, core.BuildDebugPreparation{Adapter: "missing", Program: "bin/app"}, nil, nil)
	if p.debug.activeSession() != nil {
		t.Fatal("an adapter the preparation does not name started")
	}
	want := i18n.Shared(h.app.language(), "desktop.build.noDebugAdapter")
	if got := lastNotice(h); got != want {
		t.Fatalf("notice = %q, want %q", got, want)
	}
}

// A model that came with detection turns into configurations without a model answer.
func TestStaticModelDetectionResolvesRunConfigurations(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(runConfigRoot(t))
	p := h.app.project
	since := p.runConfigs.generation
	h.app.post(func(a *App) {
		a.finishBuildDetection(p, p.build.generation, []buildInstance{runConfigInstance("app")}, nil)
	})
	awaitRunConfigsAfter(t, h, p, since)
	if len(p.runConfigs.list) != 1 || p.runConfigs.list[0].Name != "Run Main" || h.app.titleRunLabel() != "Run Main" {
		t.Fatalf("configurations = %+v failure %q", p.runConfigs.list, p.runConfigs.failure)
	}
}

// A configuration no build provider starts cannot start from the title bar either: Run names it
// and plans nothing, where the press did nothing before.
func TestTitleRunOnAConfigurationNoProviderStartsSaysSo(t *testing.T) {
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := titleRunHarness(t, gate, pluginservice.BuildRunDeclaration{ID: "application", Name: "Run", Tags: []string{"app"}})
	h.app.post(func(a *App) {
		p.runConfigs.list[0].Provider = "process"
		a.titleRun(p)
	})
	h.settle()
	want := i18n.SharedFormat(h.app.language(), "desktop.title.configurationNotStartable", map[string]string{"name": "Run Main"})
	if got := lastNotice(h); got != want {
		t.Fatalf("notice = %q, want %q", got, want)
	}
	if len(gate.requests) != 0 || p.runConfigs.pending != titleActionNone {
		t.Fatalf("%d run requests, pending %v", len(gate.requests), p.runConfigs.pending)
	}
}

// emptyRunConfigHarness opens root with one detected instance whose model declares no run,
// and returns once Core resolved the project's configurations.
func emptyRunConfigHarness(t *testing.T, root string) (*harness, *project) {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	since := p.runConfigs.generation
	h.app.post(func(a *App) {
		instance := runConfigInstance("app")
		instance.System.Runs = nil
		setDetected(p, []buildInstance{instance})
		a.refreshRunConfigurations(p)
	})
	awaitRunConfigsAfter(t, h, p, since)
	if len(p.runConfigs.list) != 0 || p.runConfigs.failure != "" {
		t.Fatalf("configurations = %+v failure %q", p.runConfigs.list, p.runConfigs.failure)
	}
	return h, p
}

// Edit Configuration on a project without configurations used to open a Run window that showed
// nothing, which looked like no reaction (#2028). It now opens the Run/Debug Configurations
// dialog with nothing selected, whose pane, as in IDEA, offers a link to the menu of kinds.
func TestEditRunConfigurationsWithoutAnyOpensTheDialog(t *testing.T) {
	h, p := emptyRunConfigHarness(t, runConfigRoot(t))
	h.app.post(func(a *App) { a.editRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the built-in kinds", func() bool { return p.runConfigs.types != nil })
	h.settle()
	d := &p.runConfigs.dialog
	if !d.open || d.selected != "" || len(d.drafts) != 0 || lastNotice(h) != "" {
		t.Fatalf("dialog open %v selected %q drafts %d, notice %q", d.open, d.selected, len(d.drafts), lastNotice(h))
	}
	language := h.app.language()
	for _, text := range []string{
		i18n.Shared(language, "desktop.runConfig.dialogTitle"),
		i18n.Shared(language, "desktop.runConfig.emptyTree"),
		i18n.Shared(language, "desktop.runConfig.addNewConfiguration"),
		i18n.Shared(language, "desktop.runConfig.orSelectToEdit"),
	} {
		if !h.shows(text) {
			t.Fatalf("%q is not shown", text)
		}
	}
	// The built-in kinds are offered by the menu the link opens.
	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.runConfig.addNewConfiguration"))))
	if shell := i18n.Shared(language, "desktop.runConfig.typeShell"); d.newMenu != runConfigNewMenuPane || !h.shows(shell) {
		t.Fatalf("menu %v, %q shown %v", d.newMenu, shell, h.shows(shell))
	}
}

// Saved configurations that no build plugin starts, such as the java.main entries an earlier
// version wrote into .lithe/run/local.json, stay out of the list; the explanation, shown while
// no built-in kind can be created, counts them instead of dropping them silently (#2028).
func TestEditRunConfigurationsCountsTheConfigurationsNoBuildPluginStarts(t *testing.T) {
	root := runConfigRoot(t)
	local := map[string]any{"version": 2, "configurations": []any{
		// A generated entry of an earlier version: Core no longer generates it and reports it orphaned.
		map[string]any{"id": "java.main:app/server:Main", "name": "Main", "provider": "java.main", "command": "java", "args": []string{"Main"}},
		// A user entry of a provider no build plugin answers: Core resolves it, the list leaves it out.
		map[string]any{"id": "user:boot", "name": "Boot", "provider": "spring-boot.maven", "command": "mvn", "args": []string{"spring-boot:run"}},
	}}
	data, err := json.Marshal(local)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".lithe", "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".lithe", "run", "local.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	h, p := emptyRunConfigHarness(t, root)
	if p.runConfigs.hidden != 2 {
		t.Fatalf("hidden = %d, want 2", p.runConfigs.hidden)
	}
	h.app.post(func(a *App) { a.editRunConfigurations(p) })
	h.settle()
	want := hiddenRunConfigurations(h.app.language(), 2)
	if !p.runConfigs.dialog.open || !h.shows(want) {
		t.Fatalf("dialog open %v, %q shown %v", p.runConfigs.dialog.open, want, h.shows(want))
	}
}

// With configurations to show, Edit Configuration opens the dialog with the chosen one selected
// and its editor read.
func TestEditRunConfigurationsOpensTheChosenOnesEditor(t *testing.T) {
	h, p := titleRunHarness(t, &testKernel{Client: core.NewClient()}, pluginservice.BuildRunDeclaration{ID: "application", Name: "Run", Tags: []string{"app"}})
	id := p.titleConfiguration().ID
	h.app.post(func(a *App) { a.editRunConfigurations(p) })
	d := &p.runConfigs.dialog
	awaitStateWithin(t, h, 10*time.Second, "the editor", func() bool {
		draft := d.drafts[id]
		return d.open && draft != nil && draft.editor != nil && !draft.editor.loading
	})
	if d.selected != id || lastNotice(h) != "" {
		t.Fatalf("selected %q, want %q; notice %q", d.selected, id, lastNotice(h))
	}
}

// When a build instance fails to load its model (#2027), the title run menu explains why
// instead of claiming there are no run configurations, and clicking opens the sync log in
// the Run window (or the Build window when no sync session exists).
func TestTitleRunMenuShowsFailedBuildModelAndOpensLogOrBuildWindow(t *testing.T) {
	t.Run("with sync session opens Run window session", func(t *testing.T) {
		h := newHarness(t, &testKernel{Client: core.NewClient()})
		h.open(runConfigRoot(t))
		p := h.app.project
		since := p.runConfigs.generation
		h.app.post(func(a *App) {
			instance := buildInstance{
				BuildInstance: core.BuildInstance{ID: "engine@.", BuildSystemID: "engine", Root: ".", DisplayName: "Engine"},
				PluginID:      "dev.example.engine",
				System:        pluginservice.BuildSystemDeclaration{DisplayName: "Engine"},
				modelError:    "JAVA_HOME is not defined\nsecond detail line",
			}
			setDetected(p, []buildInstance{instance})
			entry := &runEntry{id: "sync-1", sync: &buildSync{instance: instance.ID}, outcome: runFailed, summary: "JAVA_HOME is not defined"}
			p.build.runs = append(p.build.runs, entry)
			a.refreshRunConfigurations(p)
		})
		awaitRunConfigsAfter(t, h, p, since)
		language := h.app.language()
		wantItem := i18n.SharedFormat(language, "desktop.title.buildModelFailed", map[string]string{"name": "Engine"})
		noConfigs := i18n.Shared(language, "desktop.title.noRunConfigurations")

		h.click(center(h.button(itemRunConfig)))
		h.settle()
		if !h.shows(wantItem) {
			t.Fatalf("title run menu did not show %q", wantItem)
		}
		if h.shows(noConfigs) {
			t.Fatalf("title run menu showed misleading %q alongside build model failure", noConfigs)
		}
		h.click(center(h.menuItemHit(wantItem)))
		h.settle()
		if !h.app.chrome.isOpen(catalogIndex[itemRun]) || p.build.view != "sync-1" {
			t.Fatalf("click did not show sync session in Run window: runOpen=%v view=%q", h.app.chrome.isOpen(catalogIndex[itemRun]), p.build.view)
		}
	})

	t.Run("without sync session selects instance and opens Build window", func(t *testing.T) {
		h := newHarness(t, &testKernel{Client: core.NewClient()})
		h.open(runConfigRoot(t))
		p := h.app.project
		since := p.runConfigs.generation
		h.app.post(func(a *App) {
			first := runConfigInstance("alpha")
			first.modelLoaded = true
			second := buildInstance{
				BuildInstance: core.BuildInstance{ID: "engine@app", BuildSystemID: "engine", Root: "app", DisplayName: "Engine"},
				PluginID:      "dev.example.engine",
				System:        pluginservice.BuildSystemDeclaration{DisplayName: "Engine"},
				modelError:    "missing wrapper",
			}
			setDetected(p, []buildInstance{first, second})
			a.refreshRunConfigurations(p)
		})
		awaitRunConfigsAfter(t, h, p, since)
		language := h.app.language()
		wantItem := i18n.SharedFormat(language, "desktop.title.buildModelFailed", map[string]string{"name": "Engine (app)"})

		h.click(center(h.button(itemRunConfig)))
		h.settle()
		if !h.shows(wantItem) {
			t.Fatalf("title run menu did not show %q", wantItem)
		}
		h.click(center(h.menuItemHit(wantItem)))
		h.settle()
		if !h.app.chrome.isOpen(catalogIndex[itemBuild]) || p.build.selected != 1 {
			t.Fatalf("click did not select failed instance in Build window: buildOpen=%v selected=%d", h.app.chrome.isOpen(catalogIndex[itemBuild]), p.build.selected)
		}
	})
}

// When safe mode paused build model loading (#2027), the title run menu explains why
// and clicking opens the workspace trust prompt.
func TestTitleRunMenuShowsSafeModePausedModelAndAsksToTrust(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(runConfigRoot(t))
	p := h.app.project
	since := p.runConfigs.generation
	h.app.post(func(a *App) {
		instance := buildInstance{
			BuildInstance: core.BuildInstance{ID: "engine@.", BuildSystemID: "engine", Root: ".", DisplayName: "Engine"},
			PluginID:      "dev.example.engine",
			System:        pluginservice.BuildSystemDeclaration{DisplayName: "Engine"},
		}
		a.skipUntrustedModel(&instance)
		setDetected(p, []buildInstance{instance})
		a.refreshRunConfigurations(p)
	})
	awaitRunConfigsAfter(t, h, p, since)
	language := h.app.language()
	wantItem := i18n.SharedFormat(language, "desktop.title.buildModelSafeMode", map[string]string{"name": "Engine"})
	noConfigs := i18n.Shared(language, "desktop.title.noRunConfigurations")

	h.click(center(h.button(itemRunConfig)))
	h.settle()
	if !h.shows(wantItem) {
		t.Fatalf("title run menu did not show %q", wantItem)
	}
	if h.shows(noConfigs) {
		t.Fatalf("title run menu showed misleading %q in safe mode", noConfigs)
	}
	h.click(center(h.menuItemHit(wantItem)))
	h.settle()
	if !p.trust.asking || len(h.app.prompts.queue) != 1 {
		t.Fatalf("clicking safe mode item did not ask to trust: asking=%v queue=%d", p.trust.asking, len(h.app.prompts.queue))
	}
}
