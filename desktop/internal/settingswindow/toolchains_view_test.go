package settingswindow

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

type fakeToolchainLoader struct {
	snapshot   toolchain.Snapshot
	saved      chan []toolchain.Edit
	saveErr    error
	inspectErr error
	// loads counts the reads; the window reads on an effect goroutine.
	loads atomic.Int32
}

// Manual middle truncation must retain the actual home and the radio row's action.
func TestToolchainEllipsisKeepsFullHomeAndSelection(t *testing.T) {
	snapshot := fixtureSnapshot()
	home := "/toolchains/" + strings.Repeat("long-directory/", 6) + "compiler"
	tool := &snapshot.Tools[0]
	tool.AutomaticHome = home
	tool.Automatic.Home = &home
	tool.Installations[0].Home = home
	w, d := toolchainWindow(t, &fakeToolchainLoader{snapshot: snapshot})
	found := false
	for _, label := range d.driver.Snapshot().Labels {
		if strings.HasPrefix(label.Value, "/toolchains/") && strings.HasSuffix(label.Value, "…") {
			if err := d.driver.Move(label.Bounds.X+2, label.Bounds.Y+label.Bounds.Height/2); err != nil {
				t.Fatal(err)
			}
			found = true
			break
		}
	}
	if !found {
		t.Fatal("the installation did not show its shortened path")
	}
	if err := d.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	var full strings.Builder
	for _, label := range d.driver.Snapshot().Labels {
		if label.Layer == ui.TooltipLayer {
			full.WriteString(label.Value)
		}
	}
	if full.String() != home {
		t.Fatalf("home tooltip %q, want %q", full.String(), home)
	}
	d.chooseToolchain(home)
	toolID := w.toolchains.current().snapshot.Tools[0].ID
	if draft, ok := w.toolchains.current().draft[toolID]; !ok || draft != home {
		t.Fatalf("the installation's click did not preserve its full home: %+v", draft)
	}
}

func (f *fakeToolchainLoader) Inspect(_ context.Context, _ toolchain.Snapshot, _ string, home string) (core.ToolchainSelection, error) {
	return core.ToolchainSelection{Home: &home, Executable: home + "/bin/compiler", Version: "9.1"}, f.inspectErr
}

func (f *fakeToolchainLoader) Load(context.Context) (toolchain.Snapshot, error) {
	f.loads.Add(1)
	return f.snapshot, nil
}

func (f *fakeToolchainLoader) Save(_ context.Context, snapshot toolchain.Snapshot, edits []toolchain.Edit) (toolchain.Snapshot, error) {
	if f.saved != nil {
		select {
		case f.saved <- edits:
		default:
		}
	}
	if f.saveErr != nil {
		return snapshot, f.saveErr
	}
	// The page keeps painting from its own snapshot while this runs on the effect goroutine, and
	// that snapshot shares the Tools array with the argument. Like the real loader, which rereads
	// the project instead of editing its input, the fake returns a new array.
	snapshot.Tools = slices.Clone(snapshot.Tools)
	for _, edit := range edits {
		for index := range snapshot.Tools {
			if snapshot.Tools[index].ID == edit.Tool {
				snapshot.Tools[index].Pin = edit.Pin
			}
		}
	}
	return snapshot, nil
}

const fixtureTool = "dev.example:compiler"

func fixtureSnapshot() toolchain.Snapshot {
	home := "/fixture/compiler"
	return toolchain.Snapshot{
		Root:      "/fixture",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:            fixtureTool,
			DisplayName:   "Compiler",
			PluginID:      "dev.example",
			AutomaticHome: home,
			Automatic:     &core.ToolchainSelection{Home: &home, Executable: home + "/bin/compiler", Version: "1.2.3", Provider: "host:system"},
			Installations: []core.ToolchainInstallation{{
				Home: home, Version: "1.2.3", Provider: "host:system",
			}},
		}},
	}
}

// toolchainWindow opens a settings window on the Toolchains page with loader and waits for the
// shown scope's first load and list.
func toolchainWindow(t *testing.T, loader ToolchainLoader) (*window, *windowDriver) {
	t.Helper()
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	w.sess.page = pageToolchains
	d := openWindow(t, w)
	d.until("the toolchains to load", func() bool { return w.toolchains.current().loaded && w.toolchains.view.ready })
	d.pump()
	return w, d
}

func en(id string) string { return i18n.Shared(i18n.English, id) }

// chooseToolchain chooses the radio row labeled entry among the chosen tool's choices.
func (d *windowDriver) chooseToolchain(entry string) {
	d.t.Helper()
	d.click(entry)
	d.pump()
}

// enterToolchainDirectory opens the chosen tool's add-directory field, types home and checks it.
func (d *windowDriver) enterToolchainDirectory(home string) {
	d.t.Helper()
	d.click(en("desktop.buildSettings.addDirectory"))
	d.pump()
	d.click(en("desktop.toolchains.directory"))
	d.typeText(home)
	d.click(en("desktop.buildSettings.checkAndUse"))
}

// applyBuild clicks the footer's Apply and waits for its writes to end.
func (d *windowDriver) applyBuild() {
	d.t.Helper()
	d.click(en("desktop.buildSettings.apply"))
	d.until("the apply to end", func() bool { return !d.w.apply.active() && !d.w.toolchains.saving })
	d.pump()
}

// An unreadable enabled plugin must not make the remaining valid tools look
// like a complete catalog. The same warning is visible in both scopes.
func TestToolchainsShowPartialDiscoveryWarningInBothScopes(t *testing.T) {
	for _, scope := range []string{scopeGlobal, scopeProject} {
		t.Run(scope, func(t *testing.T) {
			fixture := fixtureSnapshot()
			fixture.DiscoveryIncomplete = true
			loader := &scopedToolchainLoader{fakeToolchainLoader{snapshot: fixture}}
			w, d := toolchainWindow(t, loader)
			if scope == scopeProject {
				w.toolchains.setScope(scopeProject)
				w.inv.Invalidate()
				d.until("the project scope", func() bool {
					return w.toolchains.current().loaded && w.toolchains.scope == scopeProject
				})
				d.pump()
			}
			if !d.text(en("desktop.toolchains.discoveryIncomplete")) {
				t.Fatal("partial tool discovery is not visible to the user")
			}
			if !d.text("Compiler") {
				t.Fatal("the readable tool was hidden by another plugin's missing manifest")
			}
			if !d.has(en("desktop.toolchains.reload")) {
				t.Fatal("no way to reload after repairing the unreadable plugin")
			}
		})
	}
}

// The chosen tool lists what it falls back to, each installation once and the link that opens
// the directory field, which stays closed until it is asked for and writes no draft.
func TestToolchainChoicesListAutomaticAndOpenTheDirectoryOnDemand(t *testing.T) {
	w, d := toolchainWindow(t, &fakeToolchainLoader{snapshot: fixtureSnapshot()})
	automatic := i18n.SharedFormat(i18n.English, "desktop.buildSettings.autoWith", map[string]string{
		"version": "1.2.3", "source": toolchainSourceLabel(i18n.English, "host:system"),
	})
	if !d.has(automatic) || !d.has("/fixture/compiler") {
		t.Fatalf("the choices have automatic = %v and the installation = %v, want both", d.has(automatic), d.has("/fixture/compiler"))
	}
	directory := en("desktop.toolchains.directory")
	if d.has(directory) {
		t.Fatal("the directory field shows before it is asked for")
	}
	d.click(en("desktop.buildSettings.addDirectory"))
	d.pump()
	if !d.has(directory) {
		t.Fatal("Add directory did not open the field")
	}
	if w.toolchains.drafts(w.toolchains.scope) != 0 {
		t.Fatal("opening the field made a draft before a directory was checked")
	}
	// The footer has a Cancel too; the field's is the one drawn first.
	d.clickHit(d.first(en("desktop.buildSettings.cancel")))
	d.pump()
	if d.has(directory) {
		t.Fatal("Cancel left the directory field")
	}
}

func TestToolchainDraftAppliesOnlyExplicitChanges(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	if state.drafts(state.scope) != 0 {
		t.Fatal("a freshly loaded page already had a draft")
	}
	if !d.hit(en("desktop.buildSettings.apply")).Disabled {
		t.Fatal("Apply is enabled without a draft")
	}
	d.chooseToolchain("/fixture/compiler")
	if state.drafts(state.scope) != 1 {
		t.Fatal("choosing an installation did not create a draft")
	}
	select {
	case edits := <-loader.saved:
		t.Fatalf("choosing wrote %+v", edits)
	default:
	}
	d.applyBuild()
	select {
	case edits := <-loader.saved:
		if len(edits) != 1 || edits[0].Pin == nil || edits[0].Pin.Home != "/fixture/compiler" {
			t.Fatalf("edits = %+v", edits)
		}
	default:
		t.Fatal("Apply did not write")
	}
	if state.current().snapshot.Tools[0].Pin == nil || state.drafts(state.scope) != 0 {
		t.Fatalf("applied state = %+v", state.current())
	}
}

func TestToolchainManualDirectoryIsValidatedBeforeAnExplicitApply(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}
	w, d := toolchainWindow(t, loader)
	d.enterToolchainDirectory("/fixture/custom")
	d.until("the checked directory", func() bool { return w.toolchains.current().draft[fixtureTool] == "/fixture/custom" })
	select {
	case edits := <-loader.saved:
		t.Fatalf("validating a directory wrote %+v", edits)
	default:
	}
	d.applyBuild()
	select {
	case edits := <-loader.saved:
		if len(edits) != 1 || edits[0].Pin == nil || edits[0].Pin.Home != "/fixture/custom" || edits[0].Pin.Version != "9.1" {
			t.Fatalf("manual directory pin = %+v", edits)
		}
	default:
		t.Fatal("the manual directory was not written")
	}
}

type scopedToolchainLoader struct{ fakeToolchainLoader }

func (f *scopedToolchainLoader) LoadScope(ctx context.Context, scope string) (toolchain.Snapshot, error) {
	result, err := f.Load(ctx)
	result.Global = scope == scopeGlobal
	return result, err
}

// Without a project the page opens on the machine defaults, and one Apply registers every
// directory the user checked, not only the one chosen.
func TestGlobalToolchainsRegisterEveryCheckedSDKWithoutAProject(t *testing.T) {
	fixture := fixtureSnapshot()
	fixture.Root = ""
	loader := &scopedToolchainLoader{fakeToolchainLoader{snapshot: fixture, saved: make(chan []toolchain.Edit, 1)}}
	w, d := toolchainWindow(t, loader)
	if !w.toolchains.current().snapshot.Global || !d.text("Compiler") {
		t.Fatal("the toolchain page requires a project or does not default to global")
	}
	d.until("the project scope to read no project", func() bool { return w.toolchains.noProject() })
	d.pump()
	if !d.hit(en("desktop.toolchains.project")).Disabled {
		t.Fatal("the project scope can be chosen without a project")
	}
	for _, home := range []string{"/fixture/sdk8", "/fixture/sdk21"} {
		d.enterToolchainDirectory(home)
		d.until("the checked SDK", func() bool { return w.toolchains.current().draft[fixtureTool] == home })
		d.pump()
	}
	if !d.has("/fixture/sdk8") || !d.has("/fixture/sdk21") {
		t.Fatal("a checked SDK is not listed as a choice")
	}
	select {
	case <-loader.saved:
		t.Fatal("directory validation published settings")
	default:
	}
	d.applyBuild()
	state := w.toolchains.current()
	if len(state.draft) != 0 {
		t.Fatal("applied registrations remain dirty")
	}
	if got := state.snapshot.Tools[0].CustomHomes; !slices.Equal(got, []string{"/fixture/sdk8", "/fixture/sdk21"}) {
		t.Fatalf("manual SDK registrations = %v", got)
	}
}

func TestToolchainDraftCancelWritesNothing(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}
	w, d := toolchainWindow(t, loader)
	d.chooseToolchain("/fixture/compiler")
	d.click(en("ui.cancel"))
	select {
	case edits := <-loader.saved:
		t.Fatalf("cancel wrote %+v", edits)
	default:
	}
	if w.toolchains.drafts(w.toolchains.scope) != 1 {
		t.Fatal("cancel must keep the draft until the window is gone")
	}
	if !w.sess.finished.Load() {
		t.Fatal("Cancel did not end the session")
	}
}

func TestToolchainApplyConflictKeepsDraft(t *testing.T) {
	loader := &fakeToolchainLoader{
		snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1),
		saveErr: toolchain.ErrPinConflict,
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.chooseToolchain("/fixture/compiler")
	d.applyBuild()
	if state.failed == nil || w.apply.failed == nil {
		t.Fatalf("the conflict did not stop the apply: page %v, footer %v", state.failed, w.apply.failed)
	}
	message := toolchainFailureMessage(i18n.Chinese, state.failed)
	if !strings.Contains(message, "重新加载") || strings.Contains(message, toolchain.ErrPinConflict.Error()) {
		t.Fatalf("conflict did not use the selected language: %q", message)
	}
	if english := toolchainFailureMessage(i18n.English, state.failed); !d.showsWrapped(english) && !d.text(english) {
		t.Fatal("the conflict is not on the page")
	}
	if state.current().snapshot.Tools[0].Pin != nil {
		t.Fatal("a conflict changed the displayed pin")
	}
	if state.drafts(state.scope) != 1 {
		t.Fatal("a conflict dropped the draft")
	}
	if w.sess.finished.Load() {
		t.Fatal("a failed apply closed the window")
	}
}

// A write that landed but could not be read back leaves no baseline to write on: the page reads
// the scope again before anything else, and the drafts, now on disk, are gone.
func TestToolchainCommittedApplyReadsTheScopeAgain(t *testing.T) {
	loader := &fakeToolchainLoader{
		snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1),
		saveErr: errors.Join(toolchain.ErrPinCommitted, errors.New("readback failed")),
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.chooseToolchain("/fixture/compiler")
	before := loader.loads.Load()
	d.applyBuild()
	if !errors.Is(w.apply.failed, toolchain.ErrPinCommitted) {
		t.Fatalf("footer failure = %v", w.apply.failed)
	}
	d.until("the scope to be read again", func() bool { return loader.loads.Load() > before && state.current().loaded })
	if state.drafts(state.scope) != 0 {
		t.Fatal("the written drafts are still shown as unapplied")
	}
}

func TestToolchainSourceFailuresUseSelectedLanguage(t *testing.T) {
	for _, code := range []string{"plugin.toolchain.invalidDocument", "plugin.toolchain.invalidIgnore"} {
		message := toolchainFailureMessage(i18n.Chinese, &core.MarketplaceRejection{Code: code, Message: "invalid fixture diagnostic"})
		if !strings.Contains(message, "重新加载") || strings.Contains(message, "fixture") {
			t.Fatalf("source failure was not localized: %q", message)
		}
	}
}

type trustToolchainLoader struct {
	fakeToolchainLoader
	globalSnapshot  toolchain.Snapshot
	untrusted       toolchain.Snapshot
	trustedSnapshot toolchain.Snapshot
	trusted         atomic.Bool
	trustCalls      []bool
	trustErr        error
}

func (l *trustToolchainLoader) LoadScope(_ context.Context, scope string) (toolchain.Snapshot, error) {
	if scope == scopeGlobal {
		return l.globalSnapshot, nil
	}
	if l.trusted.Load() {
		return l.trustedSnapshot, nil
	}
	return l.untrusted, nil
}

func (l *trustToolchainLoader) SetWorkspaceTrust(_ context.Context, _ toolchain.Snapshot, trusted bool) (toolchain.Snapshot, error) {
	l.trustCalls = append(l.trustCalls, trusted)
	if l.trustErr != nil {
		return toolchain.Snapshot{}, l.trustErr
	}
	l.trusted.Store(trusted)
	if trusted {
		return l.trustedSnapshot, nil
	}
	return l.untrusted, nil
}

func TestProjectToolchainTrustSwitchGrantsAndRevokesImmediately(t *testing.T) {
	global := fixtureSnapshot()
	global.Global = true
	global.Root = ""

	const runtime = "dev.lithe.test.runtime:interp"
	untrusted := toolchain.Snapshot{
		Root:      "/fixture/project",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:          runtime,
			DisplayName: "Synthetic Runtime",
			PluginID:    "dev.lithe.test.runtime",
			Project: []core.ToolchainProjectCandidate{{
				CandidateID: "project-venv",
				ProjectKind: "environment",
				Path:        "/fixture/project/.venv/bin/interp",
				Home:        "/fixture/project/.venv",
				Reason:      "projectCodeRequiresAction",
			}},
			Installations: []core.ToolchainInstallation{{
				Home: "/fixture/system-runtime", Version: "3.11.0", Provider: "host:system",
			}},
		}},
	}
	venvVersion := "3.12.4"
	venvHome := "/fixture/project/.venv"
	venv := core.ToolchainSelection{
		Home:        &venvHome,
		Executable:  "/fixture/project/.venv/bin/interp",
		Version:     venvVersion,
		Provider:    "host:project",
		Layer:       "project",
		ProjectCode: true,
	}
	trusted := toolchain.Snapshot{
		Root:               "/fixture/project",
		Directory:          ".",
		ProjectCodeAllowed: true,
		Tools: []toolchain.Tool{{
			ID:            runtime,
			DisplayName:   "Synthetic Runtime",
			PluginID:      "dev.lithe.test.runtime",
			AutomaticHome: venvHome,
			Automatic:     &venv,
			Effective:     &venv,
			Project: []core.ToolchainProjectCandidate{{
				CandidateID: "project-venv",
				ProjectKind: "environment",
				Path:        "/fixture/project/.venv/bin/interp",
				Home:        venvHome,
				Executable:  "/fixture/project/.venv/bin/interp",
				Version:     &venvVersion,
			}},
			Installations: []core.ToolchainInstallation{{
				Home: "/fixture/system-runtime", Version: "3.11.0", Provider: "host:system",
			}},
		}},
	}

	loader := &trustToolchainLoader{
		fakeToolchainLoader: fakeToolchainLoader{saved: make(chan []toolchain.Edit, 1)},
		globalSnapshot:      global,
		untrusted:           untrusted,
		trustedSnapshot:     trusted,
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.until("the project scope to load", func() bool { return state.projectName() != "" })
	d.pump()

	// The project's segment is named after its folder.
	d.click(i18n.SharedFormat(i18n.English, "desktop.buildSettings.scopeProjectNamed", map[string]string{"project": "project"}))
	d.until("project toolchains shown", func() bool {
		return state.scope == scopeProject && state.current().loaded && state.view.ready && state.view.got.scope == scopeProject
	})
	d.pump()

	blocked := en("desktop.toolchains.reasonProjectTrustRequired")
	if !d.has(en("desktop.buildSettings.trustProject")) || !d.text(blocked) {
		t.Fatalf("untrusted page misses its guidance: trust button %v, blocked tag %v", d.has(en("desktop.buildSettings.trustProject")), d.text(blocked))
	}

	// The banner's ⓘ explains what trusting does and where it is stored.
	help := en("desktop.toolchains.trustProjectHelp")
	infoBounds := d.hintHit(help).Bounds
	if err := d.driver.Move(infoBounds.X+infoBounds.Width/2, infoBounds.Y+infoBounds.Height/2); err != nil {
		t.Fatal(err)
	}
	d.pump()
	if !d.showsHelp(help) {
		t.Fatal("resting on the project trust ⓘ did not show its help")
	}
	// Leave the ⓘ before trusting the project.
	if err := d.driver.Move(2, 2); err != nil {
		t.Fatal(err)
	}
	d.pump()

	// Granting trust reloads at once, without an Apply.
	d.click(en("desktop.buildSettings.trustProject"))
	d.until("project trust granted", func() bool { return state.current().snapshot.ProjectCodeAllowed && !state.trusting })
	d.pump()
	if !slices.Equal(loader.trustCalls, []bool{true}) {
		t.Fatalf("trustCalls = %v, want [true]", loader.trustCalls)
	}
	resolved := i18n.SharedFormat(i18n.English, "desktop.buildSettings.autoProject", map[string]string{
		"version": venvVersion, "source": "/fixture/project/.venv/bin/interp",
	})
	if !d.has(resolved) {
		t.Fatalf("the trusted page does not fall back to %q", resolved)
	}
	if !d.has(en("desktop.toolchains.trustStatusTrusted")) {
		t.Fatal("the trusted status is missing")
	}

	// An unapplied choice survives revoking trust.
	d.chooseToolchain("/fixture/system-runtime")
	if state.drafts(scopeProject) != 1 {
		t.Fatal("expected an unapplied choice before revoking trust")
	}
	d.click(en("desktop.buildSettings.revokeTrust"))
	d.until("project trust revoked", func() bool { return !state.current().snapshot.ProjectCodeAllowed && !state.trusting })
	if !slices.Equal(loader.trustCalls, []bool{true, false}) {
		t.Fatalf("trustCalls = %v, want [true, false]", loader.trustCalls)
	}
	if state.drafts(scopeProject) != 1 {
		t.Fatal("revoking trust discarded the unapplied choice")
	}
	select {
	case edits := <-loader.saved:
		t.Fatalf("changing the project's trust wrote pins: %+v", edits)
	default:
	}
}

type runtimePrepareLoader struct {
	fakeToolchainLoader
	ready    toolchain.Snapshot
	prepared atomic.Bool
}

func (l *runtimePrepareLoader) PrepareRuntime(_ context.Context, _ string, _ toolchain.Snapshot, _ toolchain.Tool, progress func(pluginruntime.Progress)) (toolchain.Snapshot, error) {
	if progress != nil {
		progress(pluginruntime.Progress{ID: "runtime", Phase: "ready"})
	}
	l.prepared.Store(true)
	return l.ready, nil
}

func TestToolchainManagedRuntimeButtonPreparesAndClearsProblem(t *testing.T) {
	missing := toolchain.Snapshot{
		Root:      "/fixture/project",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:             "dev.example:runtime",
			DisplayName:    "Plugin Runtime",
			PluginID:       "dev.example",
			PluginName:     "Example",
			Category:       "runtime",
			Audience:       "plugin",
			ManagedRuntime: true,
			Reason:         "notFound",
		}},
	}
	home := "/managed/runtime/25"
	sel := core.ToolchainSelection{Home: &home, Executable: home + "/bin/tool", Version: "25.0.5", Provider: "host:system", Layer: "automatic"}
	ready := toolchain.Snapshot{
		Root:      "/fixture/project",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:             "dev.example:runtime",
			DisplayName:    "Plugin Runtime",
			PluginID:       "dev.example",
			PluginName:     "Example",
			Category:       "runtime",
			Audience:       "plugin",
			ManagedRuntime: true,
			AutomaticHome:  home,
			Automatic:      &sel,
			Effective:      &sel,
			Installations:  []core.ToolchainInstallation{{Home: home, Version: "25.0.5", Provider: "host:system"}},
		}},
	}
	loader := &runtimePrepareLoader{
		fakeToolchainLoader: fakeToolchainLoader{snapshot: missing},
		ready:               ready,
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.until("the missing managed tool shows its prepare button", func() bool {
		return state.current().loaded && d.has(en("desktop.toolchains.prepareRuntime"))
	})
	d.click(en("desktop.toolchains.prepareRuntime"))
	d.until("runtime preparation finished", func() bool {
		return loader.prepared.Load() && !state.preparingRuntime && d.text("25.0.5")
	})
	d.pump()
	if d.has(en("desktop.toolchains.prepareRuntime")) {
		t.Fatal("prepare button stayed visible after the managed runtime resolved")
	}
	if !d.has(en("desktop.toolchains.verifyRuntime")) {
		t.Fatal("expected Verify & Repair button on ready managed runtime")
	}
}

func TestToolchainManagedOnlyDependencyViewAndPrepare(t *testing.T) {
	missing := toolchain.Snapshot{
		Root:      "/fixture/project",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:             "dev.example:server-pkg",
			DisplayName:    "server-pkg",
			PluginID:       "dev.example",
			PluginName:     "Example",
			Category:       "runtime",
			Audience:       "plugin",
			ManagedRuntime: true,
			ManagedOnly:    true,
			Reason:         "notFound",
		}},
	}
	home := "/managed/runtime/server-pkg"
	sel := core.ToolchainSelection{Home: &home, Executable: home, Version: "1.61.0", Provider: "host:managed", Layer: "automatic"}
	ready := toolchain.Snapshot{
		Root:      "/fixture/project",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:                  "dev.example:server-pkg",
			DisplayName:         "server-pkg",
			PluginID:            "dev.example",
			PluginName:          "Example",
			Category:            "runtime",
			Audience:            "plugin",
			ManagedRuntime:      true,
			ManagedOnly:         true,
			ManagedRuntimeHomes: []string{home},
			AutomaticHome:       home,
			Automatic:           &sel,
			Effective:           &sel,
			Installations:       []core.ToolchainInstallation{{Home: home, Version: "1.61.0", Provider: "host:managed"}},
		}},
	}
	loader := &runtimePrepareLoader{
		fakeToolchainLoader: fakeToolchainLoader{snapshot: missing},
		ready:               ready,
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.until("the missing managed-only dependency shows its prepare button", func() bool {
		return state.current().loaded && d.has(en("desktop.toolchains.prepareRuntime"))
	})
	if d.has(en("desktop.buildSettings.addDirectory")) {
		t.Fatal("managed-only dependency should not expose manual add-directory button")
	}
	d.click(en("desktop.toolchains.prepareRuntime"))
	d.until("managed-only preparation finished", func() bool {
		return loader.prepared.Load() && !state.preparingRuntime && d.text("1.61.0")
	})
	d.pump()
	if d.has(en("desktop.toolchains.prepareRuntime")) {
		t.Fatal("prepare button stayed visible after managed-only dependency resolved")
	}
	if !d.text(en("desktop.toolchains.managedDirectory")) {
		t.Fatal("expected Folder label on managed-only dependency")
	}
	if !d.text(en("desktop.buildSettings.sourceManaged")) {
		t.Fatal("expected Managed runtime source tag on managed-only dependency")
	}
	if !d.has(en("desktop.toolchains.verifyRuntime")) {
		t.Fatal("expected Verify & Repair button on ready managed-only dependency")
	}
	if d.has(en("desktop.buildSettings.addDirectory")) {
		t.Fatal("ready managed-only dependency should not expose manual add-directory button")
	}
}
