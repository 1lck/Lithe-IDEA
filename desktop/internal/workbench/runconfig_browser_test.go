package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// runBrowserInstances are two build systems: Engine runs its app target as an application and
// serves it as a service, and Alpha runs its own app target as an application.
func runBrowserInstances() []buildInstance {
	engine := runConfigInstance("app")
	engine.System.DisplayName = "Engine"
	engine.System.Runs = append(engine.System.Runs, pluginservice.BuildRunDeclaration{ID: "serve", Name: "Serve", Execution: "service", Tags: []string{"app"}})
	alpha := runConfigInstance("tools")
	alpha.BuildInstance = core.BuildInstance{ID: "alpha@tools", PluginID: "dev.example.alpha", BuildSystemID: "alpha", Root: "tools"}
	alpha.PluginID = "dev.example.alpha"
	alpha.System.DisplayName = "Alpha"
	return []buildInstance{engine, alpha}
}

// The Run tool window lists the run configurations under the build system that provides them,
// in a scope of every configuration, the pinned ones or one execution kind, each scope with its
// count. A pin is written into the client's store, outside the project, and read back with the
// list; a group closes and opens; a double click runs a configuration through its provider; and
// the row of the configuration that runs stops it.
func TestRunConfigurationListScopesGroupsPinsAndRuns(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"app/server", "tools/server"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h := newHarnessWithLanguages(t, gate, []string{"en-US"})
	h.open(root)
	p := h.app.project
	lang := h.app.language()
	if err := h.driver.Resize(1280, 1200); err != nil {
		t.Fatal(err)
	}
	h.app.post(func(a *App) {
		p.build.instances, p.build.loaded = runBrowserInstances(), true
		a.refreshRunConfigurations(p)
		if !a.chrome.isOpen(catalogIndex[itemRun]) {
			a.reduceChrome(core.SetChromeOpen(itemRun, true))
		}
	})
	s := &p.runConfigs
	b := &s.browser
	awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool { return s.generation > 0 && !s.loading })
	h.settle()
	if s.failure != "" || len(s.list) != 3 {
		t.Fatalf("configurations = %+v, failure %q", s.list, s.failure)
	}
	var serve string
	for _, configuration := range s.list {
		if configuration.Name == "Serve Main" {
			serve = configuration.ID
		}
	}
	if serve == "" {
		t.Fatalf("no service configuration among %+v", s.list)
	}
	if got := s.scopes(); !slices.Equal(got, []string{"", runScopePinned, "service", "application"}) {
		t.Fatalf("scopes %q, want every, pinned, then the service and application kinds", got)
	}
	if !h.shows(i18n.Shared(lang, "native.runConfigurations")) || !h.shows(h.app.runScopeLabel(s, "")) {
		t.Fatal("the Run tool window does not show the configurations under the scope of all of them")
	}
	if h.app.runScopeLabel(s, "") != "All configurations (3)" || h.app.runScopeLabel(s, "application") != "Applications (2)" {
		t.Fatalf("scope labels %q and %q", h.app.runScopeLabel(s, ""), h.app.runScopeLabel(s, "application"))
	}
	rows := func() []string {
		var names []string
		for _, row := range b.rows {
			if row.configuration < 0 {
				names = append(names, "["+b.groups[row.group].title+"]")
			} else {
				names = append(names, s.list[row.configuration].Name)
			}
		}
		return names
	}
	// Core tells the two configurations of the same name apart by their roots.
	if got := rows(); !slices.Equal(got, []string{"[Alpha]", "Run Main (tools)", "[Engine]", "Run Main (app)", "Serve Main"}) {
		t.Fatalf("rows %q, want the groups by title and their configurations by name", got)
	}

	// Pinning writes the client's store, never the project, and the pin is read back.
	h.rightClickNamed("Serve Main")
	h.click(center(h.menuItemHit(i18n.Shared(lang, "native.pinConfiguration"))))
	h.settle()
	if !b.pins[serve] {
		t.Fatal("the menu did not pin the configuration")
	}
	stored := map[string][]string{}
	if _, err := h.store.Load(runConfigPinsFile, &stored); err != nil || !slices.Equal(stored[filepath.Clean(root)], []string{serve}) {
		t.Fatalf("stored pins %v (%v), want the service configuration under the project", stored, err)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe")); !os.IsNotExist(err) {
		t.Fatalf("pinning wrote into the project: %v", err)
	}
	h.app.post(func(a *App) {
		b.pins, b.pinsLoaded = nil, false
		a.loadRunConfigPins(p)
		b.scope = runScopePinned
	})
	h.settle()
	if !b.pins[serve] || h.app.runScopeLabel(s, runScopePinned) != "Pinned (1)" {
		t.Fatalf("pins read back %v, label %q", b.pins, h.app.runScopeLabel(s, runScopePinned))
	}
	if got := rows(); !slices.Equal(got, []string{"[Engine]", "Serve Main"}) {
		t.Fatalf("pinned rows %q", got)
	}

	// A group closes over its configurations and opens again.
	h.clickNamed(i18n.Shared(lang, "native.collapseSection") + " Engine")
	h.settle()
	if got := rows(); !slices.Equal(got, []string{"[Engine]"}) {
		t.Fatalf("rows of the closed group %q", got)
	}
	h.clickNamed(i18n.Shared(lang, "native.expandSection") + " Engine")
	h.settle()
	if got := rows(); !slices.Equal(got, []string{"[Engine]", "Serve Main"}) {
		t.Fatalf("rows of the opened group %q", got)
	}

	// A double click runs the configuration through its provider's run.
	at := center(h.pageHit("Serve Main").Bounds)
	if err := h.driver.DoubleClick(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 10*time.Second, "the provider run request", func() bool { return len(gate.requests) == 1 })
	if request := <-gate.requests; request.Run != "serve" || request.Target == nil || request.Target.Name != "Main" {
		t.Fatalf("run request %+v, want the service run of the main target", request)
	}
	h.settle()

	// The row of the configuration that runs shows it running, and its button stops it.
	operation := &buildOperation{configuration: serve}
	h.app.post(func(*App) { p.build.operation = operation })
	h.settle()
	if !h.shows(i18n.Shared(lang, "native.running")) {
		t.Fatal("the running configuration's row does not say it runs")
	}
	h.clickNamed(i18n.Shared(lang, "native.stopRun.variant2"))
	h.settle()
	if !operation.cancelled {
		t.Fatal("the row's stop button did not stop the run")
	}
	h.app.post(func(*App) { p.build.operation = nil })
	h.settle()

	// Unpinning drops the project from the store.
	h.rightClickNamed("Serve Main")
	h.click(center(h.menuItemHit(i18n.Shared(lang, "native.unpinConfiguration"))))
	h.settle()
	stored = map[string][]string{}
	if _, err := h.store.Load(runConfigPinsFile, &stored); err != nil || len(b.pins) != 0 || len(stored) != 0 {
		t.Fatalf("after unpinning: pins %v, stored %v (%v)", b.pins, stored, err)
	}
	if got := rows(); len(got) != 0 || !h.shows(i18n.Shared(lang, "native.noConfigurationsInThisScope")) {
		t.Fatalf("the pinned scope without pins shows %q", got)
	}
}
