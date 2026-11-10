package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/projectgen"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// pageHit finds a control of the New Project page by its accessible name, the
// front-most first. The backdrop and the text labels beside controls are not controls.
func (h *harness) pageHit(name string) gfx.Hit {
	h.t.Helper()
	hit, ok := h.findPageHit(name)
	if !ok {
		h.t.Fatalf("no control named %q", name)
	}
	return hit
}

func (h *harness) findPageHit(name string) (gfx.Hit, bool) {
	hits := h.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hit := hits[i]; hit.Label == name && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			return hit, true
		}
	}
	return gfx.Hit{}, false
}

func (h *harness) clickNamed(name string) {
	h.t.Helper()
	h.click(center(h.pageHit(name).Bounds))
}

// openNewProjectSheet opens the sheet from the welcome page and waits until the
// catalog the plugins declared has been listed.
func (h *harness) openNewProjectSheet() {
	h.t.Helper()
	h.clickNamed(h.app.text.Welcome.NewProject)
	h.await("the generator catalog", func() bool { return h.app.newProject.catalogLoaded })
}

const generatorFixtures = "../../../shared/contracts/plugins/v1/fixtures/project-generators"

func fixtureGeneratorPlugin(t *testing.T) pluginservice.GeneratorPlugin {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(generatorFixtures, "project-generator.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	path, err := filepath.Abs(generatorFixtures)
	if err != nil {
		t.Fatal(err)
	}
	return pluginservice.GeneratorPlugin{PluginID: "dev.lithe.fixture.project-generator", Version: "1.0.0", Path: path, Enabled: true, Manifest: data}
}

func fixtureJavaTools() map[string]toolList {
	return map[string]toolList{"java": {
		Installations: []toolInstall{
			{ProjectToolInstallation: core.ProjectToolInstallation{Home: "/opt/jdk-21", Executable: "/opt/jdk-21/bin/java", Version: "21.0.4"}, Provider: "host:system"},
			{ProjectToolInstallation: core.ProjectToolInstallation{Home: "/opt/jdk-11", Executable: "/opt/jdk-11/bin/java", Version: "11.0.2"}, Provider: "host:system"},
		},
		Default: "/opt/jdk-21",
	}}
}

// newGeneratorHarness is a window whose plugins and tool discovery are the
// fixtures'. The sheet is not opened yet.
func newGeneratorHarness(t *testing.T, kernel Kernel, plugins ...pluginservice.GeneratorPlugin) *harness {
	t.Helper()
	h := newHarnessWithLanguages(t, kernel, []string{"en-US"})
	h.app.generatorPlugins = func(context.Context) ([]pluginservice.GeneratorPlugin, error) { return plugins, nil }
	h.app.projectToolLists = func(_ context.Context, tools []string) (map[string]toolList, error) {
		lists := map[string]toolList{}
		for _, tool := range tools {
			lists[tool] = fixtureJavaTools()[tool]
		}
		return lists, nil
	}
	return h
}

func TestWelcomeCreatesEmptyProjectWithGitThroughCore(t *testing.T) {
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &gitKernel{Client: core.NewClient()}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	if !h.app.newProject.open || !h.shows("Empty Project") {
		t.Fatal("the welcome action did not open New Project")
	}
	if !h.shows("Get more languages and frameworks from plugins…") {
		t.Fatal("the marketplace entry is missing its localized label")
	}
	h.app.newProject.parent = parent
	h.app.newProject.name = "hello project"
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickNamed("Create Git repository")
	if !h.app.newProject.git {
		t.Fatal("the Git checkbox did not toggle")
	}
	h.clickNamed("Create")
	destination := filepath.Join(parent, "hello project")
	if h.app.newProject.open || h.app.project == nil || h.app.project.root != destination {
		t.Fatalf("new project open = %v, project = %+v", h.app.newProject.open, h.app.project)
	}
	info, err := os.Stat(filepath.Join(destination, ".git"))
	if err != nil || !info.IsDir() {
		t.Fatalf("Git directory = %v, error = %v", info, err)
	}
}

func TestNewProjectNameAcceptsTypingAndShowsPreview(t *testing.T) {
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	h.app.newProject.parent = parent
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickNamed("Name")
	if _, err := h.driver.ShortcutChord(ui.Primary, 'a'); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("typed"); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.newProject.name != "typed" || !h.shows(filepath.Join(parent, "typed")) {
		t.Fatalf("name = %q, preview shown = %v", h.app.newProject.name, h.shows(filepath.Join(parent, "typed")))
	}
}

func TestNewProjectExplainsInvalidNameAndExistingFolderBeforeCreating(t *testing.T) {
	parent := t.TempDir()
	if err := os.Mkdir(filepath.Join(parent, "taken"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	n := &h.app.newProject
	n.parent, n.name = parent, "taken"
	h.app.invalidator.Invalidate()
	h.await("the existing folder to be reported", func() bool { return h.shows("already exists") })
	if hit := h.pageHit("Create"); !hit.Disabled {
		t.Fatal("Create stays enabled for an existing folder")
	}
	n.name = "-option"
	h.app.invalidator.Invalidate()
	h.await("the invalid name to be reported", func() bool { return h.shows("Enter a valid project name") })
	if hit := h.pageHit("Create"); !hit.Disabled {
		t.Fatal("Create stays enabled for an invalid name")
	}
}

func TestNewProjectRejectsInvalidNamesAndExistingDirectories(t *testing.T) {
	parent := t.TempDir()
	kernel := &testKernel{Client: core.NewClient()}
	for _, name := range []string{"../outside", "-option", "project:other", " trailing "} {
		result := createEmptyProject(context.Background(), kernel, parent, name, false)
		if result.reason != "invalidName" || result.created {
			t.Fatalf("name %q: %+v", name, result)
		}
	}
	if err := os.Mkdir(filepath.Join(parent, "existing"), 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(parent, "existing", "marker")
	if err := os.WriteFile(marker, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	result := createEmptyProject(context.Background(), kernel, parent, "existing", false)
	if result.reason != "exists" || result.created {
		t.Fatalf("existing destination: %+v", result)
	}
	if content, err := os.ReadFile(marker); err != nil || string(content) != "keep" {
		t.Fatalf("existing content = %q, error = %v", content, err)
	}
}

func TestNewProjectGitRefusesToInitializeInsideExistingRepository(t *testing.T) {
	parent := newTestRepository(t)
	kernel := &testKernel{Client: core.NewClient()}
	result := createEmptyProject(context.Background(), kernel, parent, "nested", true)
	if !result.created || result.reason != "gitFailed" || result.err == nil {
		t.Fatalf("nested Git initialization = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(parent, "nested")); err != nil {
		t.Fatalf("created folder was lost: %v", err)
	}
	if _, err := os.Stat(filepath.Join(parent, "nested", ".git")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected nested repository: %v", err)
	}
}

func TestNewProjectCancellationBeforeCreationLeavesNoDirectory(t *testing.T) {
	parent := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result := createEmptyProject(ctx, &testKernel{Client: core.NewClient()}, parent, "cancelled", false)
	if result.created || !errors.Is(result.err, context.Canceled) {
		t.Fatalf("cancelled creation = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(parent, "cancelled")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancelled creation left a directory: %v", err)
	}
}

func TestProjectParentExpandsOnlyHomeShorthand(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "home", "user")
	if got := projectParent("~/projects", home); got != filepath.Join(home, "projects") {
		t.Fatalf("expanded home: %q", got)
	}
	if got := projectParent("~other/projects", home); got != "~other/projects" {
		t.Fatalf("expanded another user: %q", got)
	}
}

type failingNewProjectGitKernel struct{ *testKernel }

func (k *failingNewProjectGitKernel) InitializeGit(context.Context, string) error {
	return errors.New("fixture Git initialization failed")
}

func TestNewProjectGitFailureKeepsDirectoryAndOffersToOpen(t *testing.T) {
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &failingNewProjectGitKernel{&testKernel{Client: core.NewClient()}}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	h.app.newProject.parent = parent
	h.app.newProject.name = "created"
	h.app.newProject.git = true
	h.app.submitNewProject()
	h.settle()
	path := filepath.Join(parent, "created")
	if h.app.newProject.created != path || h.app.newProject.err == "" || h.app.project != nil {
		t.Fatalf("failed Git initialization: %+v", h.app.newProject)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	h.clickNamed("Open Created Project")
	if h.app.project == nil || h.app.project.root != path {
		t.Fatal("could not open the created directory")
	}
}

// The sheet is a Frame popup and the start screen a page, so the sheet cannot
// name the button to give the keyboard back to: closing only has to close.
func TestNewProjectEscapeClosesTheSheetOnTheWelcomeScreen(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	if h.driver.Snapshot().Focused != h.pageHit("Search").ID {
		t.Fatal("search did not receive focus")
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.newProject.open {
		t.Fatal("Escape did not close the dialog")
	}
}

func TestNewProjectSearchUsesCoreAndKeepsSelectedDetails(t *testing.T) {
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, fixtureGeneratorPlugin(t))
	h.openNewProjectSheet()
	for _, name := range []string{"App", "Initializr", "Archetype", "Empty Project"} {
		if !h.shows(name) {
			t.Fatalf("%s is not listed", name)
		}
	}
	h.app.newProject.search = "Initial"
	h.app.invalidator.Invalidate()
	h.await("the search to hide the other entries", func() bool { return !h.shows("Archetype") })
	if !h.shows("Initializr") || h.shows("Empty Project") {
		t.Fatalf("search kept the wrong rows: initializr=%v empty=%v", h.shows("Initializr"), h.shows("Empty Project"))
	}
	if !h.shows("A basic project with a free structure.") {
		t.Fatal("search hid the selected entry's form")
	}
	h.click(center(h.pageHit("Clear search").Bounds))
	h.await("the search to be cleared", func() bool { return h.shows("Empty Project") && h.shows("Archetype") })
	if h.app.newProject.search != "" {
		t.Fatalf("search = %q", h.app.newProject.search)
	}
}

type delayedNewProjectSearchKernel struct {
	*testKernel
	started, release chan struct{}
	once             sync.Once
}

func (k *delayedNewProjectSearchKernel) RankNames(ctx context.Context, query string, candidates []core.RankCandidate) ([]int, error) {
	if query == "unmatch-xyz" {
		k.once.Do(func() { close(k.started) })
		<-k.release // Deliberately returns an old result after the query changed.
		return nil, nil
	}
	return k.Client.RankNames(ctx, query, candidates)
}

func TestNewProjectSearchDropsStaleResults(t *testing.T) {
	k := &delayedNewProjectSearchKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{}), release: make(chan struct{})}
	h := newHarnessWithLanguages(t, k, []string{"en-US"})
	released := false
	t.Cleanup(func() {
		if !released {
			close(k.release)
		}
	})
	h.clickNamed(h.app.text.Welcome.NewProject)
	h.app.newProject.search = "unmatch-xyz"
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-k.started:
	case <-timer.C:
		t.Fatal("search did not start")
	}
	h.app.newProject.search = ""
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	close(k.release)
	released = true
	h.settle()
	if !h.shows("Empty Project") {
		t.Fatal("stale search result hid the restored row")
	}
}

func TestNewProjectSheetBackdropDismissesWithoutOpeningUnderlyingProject(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.clickNamed(h.app.text.Welcome.NewProject)
	if err := h.driver.Click(2, 2); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.newProject.open || h.app.project != nil {
		t.Fatal("backdrop did not dismiss only the sheet")
	}
}

func TestNewProjectSheetKeepsFocusAndBlocksSurfaceClicks(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.clickNamed(h.app.text.Welcome.NewProject)
	if err := h.driver.Click(600, 400); err != nil {
		t.Fatal(err)
	}
	if !h.app.newProject.open || h.app.project != nil {
		t.Fatal("an empty area inside the sheet dismissed it or reached the background")
	}
	for range 8 {
		if err := h.driver.Key(gfx.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
		focus := h.focusedName()
		if focus == h.app.text.Welcome.NewProject || focus == h.app.text.Welcome.Open || focus == i18n.Shared(h.app.language(), "desktop.clone.more") {
			t.Fatalf("keyboard focus escaped the sheet to %q", focus)
		}
	}
}

type blockedNewProjectKernel struct {
	*testKernel
	started chan struct{}
	once    sync.Once
}

func (k *blockedNewProjectKernel) CheckProjectName(ctx context.Context, _ string) (core.ProjectNameProblem, error) {
	k.once.Do(func() { close(k.started) })
	<-ctx.Done()
	return "", ctx.Err()
}

func TestClosingWindowCancelsPendingNewProject(t *testing.T) {
	kernel := &blockedNewProjectKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openNewProject(surfaceButton)
	h.app.newProject.parent = t.TempDir()
	h.app.newProject.name = "not-created"
	h.app.submitNewProject()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-kernel.started:
	case <-timer.C:
		t.Fatal("project validation did not start")
	}
	h.app.closed()
	h.settle()
	if h.app.newProject.open || h.app.project != nil {
		t.Fatal("closing the window left a new project operation active")
	}
}

func TestNewProjectCancelWaitsForValidation(t *testing.T) {
	kernel := &blockedNewProjectKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openNewProject(surfaceButton)
	parent := t.TempDir()
	h.app.newProject.parent = parent
	h.app.newProject.name = "not-created"
	h.app.submitNewProject()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-kernel.started:
	case <-timer.C:
		t.Fatal("project validation did not start")
	}
	h.app.cancelNewProject()
	if !h.app.newProject.busy || !h.app.newProject.cancelling {
		t.Fatal("cancel did not wait for the worker")
	}
	h.settle()
	if h.app.newProject.open || h.app.project != nil {
		t.Fatal("cancelled validation did not close the sheet")
	}
	if _, err := os.Stat(filepath.Join(parent, "not-created")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancelled validation created a directory: %v", err)
	}
}

type blockedNewProjectGitKernel struct {
	*testKernel
	started chan struct{}
}

func (k *blockedNewProjectGitKernel) InitializeGit(ctx context.Context, _ string) error {
	close(k.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestNewProjectCancelAfterMkdirOffersCreatedFolder(t *testing.T) {
	kernel := &blockedNewProjectGitKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openNewProject(surfaceButton)
	parent := t.TempDir()
	h.app.newProject.parent = parent
	h.app.newProject.name = "created"
	h.app.newProject.git = true
	h.app.submitNewProject()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-kernel.started:
	case <-timer.C:
		t.Fatal("Git initialization did not start")
	}
	h.app.cancelNewProject()
	h.settle()
	if !h.app.newProject.open || h.app.newProject.created != filepath.Join(parent, "created") || h.app.newProject.err == "" {
		t.Fatal("cancelled Git initialization did not retain and explain the created folder")
	}
}

func TestNewProjectFolderPickerAndGitLabel(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.clickNamed(h.app.text.Welcome.NewProject)
	parent := t.TempDir()
	if err := h.driver.QueueOpenDirectory(parent, nil); err != nil {
		t.Fatal(err)
	}
	h.clickNamed("Choose…")
	if h.app.newProject.parent != parent {
		t.Fatal("folder picker did not set the location")
	}
	h.clickNamed("Create Git repository")
	if !h.app.newProject.git {
		t.Fatal("clicking the Git checkbox did not select it")
	}
}

func TestNewProjectMarketplaceEntryInvokesPluginSettings(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	h.clickNamed(h.app.text.Welcome.NewProject)
	h.clickNamed("Get more languages and frameworks from plugins…")
	log.mu.Lock()
	defer log.mu.Unlock()
	for _, event := range log.events {
		if event.Event == "app.action.performed" && event.Fields["action"] == "settings.open" {
			return
		}
	}
	t.Fatal("marketplace entry did not invoke plugin settings")
}

// TestNewProjectHelperProcess is the scaffolding tool the command steps run: the
// test binary starts itself with the arguments the generator's plan carries.
func TestNewProjectHelperProcess(t *testing.T) {
	mode := os.Getenv("LITHE_NP_HELPER")
	if mode == "" {
		return
	}
	switch mode {
	case "scaffold":
		name := os.Getenv("LITHE_NP_NAME")
		_ = os.MkdirAll(filepath.Join(name, "src"), 0o755)
		_ = os.WriteFile(filepath.Join(name, "pom.xml"), []byte("<project/>"), 0o644)
		_ = os.WriteFile(filepath.Join(name, "src", "label.txt"), []byte(os.Getenv("LITHE_NP_LABEL")), 0o644)
		fmt.Println("scaffolded " + name)
		os.Exit(0)
	case "fail":
		fmt.Println("about to fail")
		os.Exit(3)
	case "block":
		fmt.Println("ready")
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	os.Exit(9)
}

// commandGeneratorPlugin declares generators that run the test binary as their
// scaffolding command, so no installed developer tool is needed.
func commandGeneratorPlugin(t *testing.T) pluginservice.GeneratorPlugin {
	t.Helper()
	step := func(mode string) map[string]any {
		step := map[string]any{
			"kind": "command", "command": "scaffold-tool", "mayUseNetwork": false, "timeoutSeconds": 60,
			"arguments": []string{"-test.run=^TestNewProjectHelperProcess$"},
			"environment": map[string]string{
				"LITHE_NP_HELPER": mode, "LITHE_NP_NAME": "${project.name}", "LITHE_NP_LABEL": "${field.label}",
			},
		}
		if mode == "scaffold" {
			step["collect"] = "${project.name}"
		}
		return step
	}
	generator := func(id, title, mode string) map[string]any {
		return map[string]any{
			"id": id, "displayName": title, "section": "generator",
			"fields": []map[string]any{{"id": "label", "type": "text", "title": "Label", "default": "hello"}},
			"steps":  []map[string]any{step(mode)},
		}
	}
	manifest, err := json.Marshal(map[string]any{
		"schemaVersion": 2, "id": "dev.lithe.test.scaffold", "displayName": "Scaffold", "version": "1.0.0",
		"pluginAPIVersion": 3, "requires": map[string]int{"projectGenerators": 1},
		"vendor":      map[string]string{"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions": []string{"project.generate"}, "activationEvents": []string{},
		"projectGenerators": []map[string]any{
			generator("scaffold", "Scaffold", "scaffold"), generator("failing", "Failing", "fail"), generator("blocking", "Blocking", "block"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return pluginservice.GeneratorPlugin{PluginID: "dev.lithe.test.scaffold", Version: "1.0.0", Path: t.TempDir(), Enabled: true, Manifest: manifest}
}

func useHelperExecutable(t *testing.T, h *harness) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	h.app.projectCommand = func(_ context.Context, command string) (projectgen.Command, error) {
		if command != "scaffold-tool" {
			return projectgen.Command{}, fmt.Errorf("%w: %s", projectgen.ErrCommandMissing, command)
		}
		return projectgen.Command{Executable: executable}, nil
	}
}

// chooseGenerator selects an entry of the list and waits for its form.
func (h *harness) chooseGenerator(name, key string) {
	h.t.Helper()
	h.clickNamed(name)
	h.await("the form of "+name, func() bool {
		form := h.app.newProject.forms[key]
		if form != nil && form.form != nil && form.formKey == form.currentKey && !form.form.Valid {
			h.t.Fatalf("the form of %s is not valid: %+v (name problem %v)", name, form.form.Fields, form.form.ProjectName.Problem)
		}
		return h.app.newProject.choice == key && form != nil && form.ready()
	})
}

func (h *harness) directoryEntries(directory string) []string {
	h.t.Helper()
	found, err := os.ReadDir(directory)
	if err != nil {
		h.t.Fatal(err)
	}
	names := []string{}
	for _, entry := range found {
		names = append(names, entry.Name())
	}
	return names
}

func TestNewProjectListsPluginGeneratorsInTheirSections(t *testing.T) {
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, fixtureGeneratorPlugin(t))
	h.openNewProjectSheet()
	rows := h.app.newProject.sidebarRows(h.app.language())
	var listed []string
	for _, row := range rows {
		listed = append(listed, row.title)
	}
	// "New Project" holds the plugin's project entry and then the host's empty
	// project; "Generators" follows by order, then name.
	want := []string{"New Project", "App", "Empty Project", "Generators", "Initializr", "Archetype"}
	if strings.Join(listed, "|") != strings.Join(want, "|") {
		t.Fatalf("list = %v, want %v", listed, want)
	}
	if h.app.newProject.choice != emptyProjectKey || !h.shows("A basic project with a free structure.") {
		t.Fatal("the empty project is not selected first")
	}
}

func TestNewProjectDisabledPluginGeneratorsAreNotListed(t *testing.T) {
	plugin := fixtureGeneratorPlugin(t)
	plugin.Enabled = false
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, plugin)
	h.openNewProjectSheet()
	if h.shows("Archetype") || h.shows("Initializr") || !h.shows("Empty Project") {
		t.Fatal("a disabled plugin's generators are listed")
	}
}

func TestNewProjectConditionalFieldsAndTemplateFilesFromCore(t *testing.T) {
	parent := t.TempDir()
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, fixtureGeneratorPlugin(t))
	h.openNewProjectSheet()
	h.chooseGenerator("App", "dev.lithe.fixture.project-generator/app")
	n := &h.app.newProject
	n.parent, n.name = parent, "demo"
	h.app.invalidator.Invalidate()
	if !h.shows("Build system") || !h.shows("JDK") || !h.shows("Add sample code") {
		t.Fatal("the declared fields are not drawn")
	}
	if h.shows("Advanced Settings") {
		t.Fatal("the field that is only visible with Maven is offered without Maven")
	}
	h.clickNamed("Maven")
	h.await("the Maven-only field", func() bool { return h.shows("Advanced Settings") })
	h.clickNamed("Advanced Settings")
	h.await("the group field", func() bool { return h.shows("Group") })
	h.clickNamed("None")
	h.await("the Maven-only field to disappear", func() bool { return !h.shows("Advanced Settings") })
	h.clickNamed("Maven")
	h.await("the Maven-only field again", func() bool { return h.shows("Advanced Settings") })
	h.awaitValidForm()
	h.clickNamed("Create")
	h.awaitProjectOpen()
	root := filepath.Join(parent, "demo")
	if h.app.project.root != root {
		t.Fatalf("opened %q, want %q", h.app.project.root, root)
	}
	readme, err := os.ReadFile(filepath.Join(root, "README.md"))
	if err != nil || !strings.HasPrefix(string(readme), "# demo\n") {
		t.Fatalf("README.md = %q, %v", readme, err)
	}
	main, err := os.ReadFile(filepath.Join(root, "src", "com", "example", "Main.java"))
	if err != nil || string(main) != "package com.example;\n\nclass Main {}\n" {
		t.Fatalf("Main.java = %q, %v", main, err)
	}
	if _, err := os.Stat(filepath.Join(root, ".gitignore")); err != nil {
		t.Fatalf("the dot- file was not written: %v", err)
	}
	if names := h.directoryEntries(parent); len(names) != 1 {
		t.Fatalf("the parent holds %v, want only the project", names)
	}
	h.await("the declared file to open", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(filepath.Join(root, "src", "com", "example", "Main.java")) != nil
	})
}

func TestNewProjectGeneratorNeedsAValidFormAndOffersToEnableRequirements(t *testing.T) {
	plugin := fixtureGeneratorPlugin(t)
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, plugin)
	// No installation of the tool: the required runtime field is not satisfied.
	h.app.projectToolLists = func(context.Context, []string) (map[string]toolList, error) { return map[string]toolList{}, nil }
	h.openNewProjectSheet()
	h.chooseGeneratorWithoutWaiting("App")
	h.await("the form", func() bool { return h.app.newProject.form() != nil && h.app.newProject.form().form != nil })
	if !h.shows("No installation was found.") {
		t.Fatal("a tool without installations is not explained")
	}
	if !h.pageHit("Create").Disabled {
		t.Fatal("Create is enabled while a required tool field has no installation")
	}
	if _, offered := h.findPageHit("Find in Marketplace"); !h.shows("This generator needs java.") || !offered {
		t.Fatal("the missing language plugin is not offered in the marketplace")
	}
}

// awaitValidForm paints what the test just entered, then waits until Core has
// answered for it and the form can be submitted. Checking before the paint
// would trust the previous frame's button.
func (h *harness) awaitValidForm() {
	h.t.Helper()
	h.app.invalidator.Invalidate()
	h.settle()
	h.await("a valid form", func() bool {
		form := h.app.newProject.form()
		return form != nil && form.ready() && !h.pageHit("Create").Disabled
	})
}

// awaitProjectOpen waits until the created project is open, and reports the
// window's own explanation if creating it failed instead.
func (h *harness) awaitProjectOpen() {
	h.t.Helper()
	h.await("the project to open", func() bool {
		if n := &h.app.newProject; n.err != "" {
			h.t.Fatalf("creating the project failed: %s", n.err)
		}
		return h.app.project != nil && !h.app.newProject.open
	})
}

func (h *harness) chooseGeneratorWithoutWaiting(name string) {
	h.t.Helper()
	h.clickNamed(name)
	h.await("the selection of "+name, func() bool { return h.app.newProject.choice != emptyProjectKey })
}

func TestNewProjectCommandStepRunsTheToolAndCollectsItsOutput(t *testing.T) {
	parent := t.TempDir()
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, commandGeneratorPlugin(t))
	useHelperExecutable(t, h)
	h.openNewProjectSheet()
	h.chooseGenerator("Scaffold", "dev.lithe.test.scaffold/scaffold")
	n := &h.app.newProject
	n.parent, n.name = parent, "demo"
	h.app.invalidator.Invalidate()
	h.awaitValidForm()
	h.clickNamed("Create")
	h.awaitProjectOpen()
	root := filepath.Join(parent, "demo")
	label, err := os.ReadFile(filepath.Join(root, "src", "label.txt"))
	if err != nil || string(label) != "hello" {
		t.Fatalf("label.txt = %q, %v (the field default must reach the tool through the plan)", label, err)
	}
	if _, err := os.Stat(filepath.Join(root, "pom.xml")); err != nil {
		t.Fatalf("the collected project root has no pom.xml: %v", err)
	}
	if names := h.directoryEntries(parent); len(names) != 1 || names[0] != "demo" {
		t.Fatalf("the parent holds %v", names)
	}
}

func TestNewProjectFailedCommandShowsItsOutputAndLeavesNothing(t *testing.T) {
	parent := t.TempDir()
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, commandGeneratorPlugin(t))
	useHelperExecutable(t, h)
	h.openNewProjectSheet()
	h.chooseGenerator("Failing", "dev.lithe.test.scaffold/failing")
	n := &h.app.newProject
	n.parent, n.name = parent, "demo"
	h.app.invalidator.Invalidate()
	h.awaitValidForm()
	h.clickNamed("Create")
	h.await("the failure", func() bool { return !n.busy && n.err != "" })
	if !strings.Contains(n.err, "command failed") || !h.shows("about to fail") {
		t.Fatalf("err = %q, output shown = %v", n.err, h.shows("about to fail"))
	}
	if n.created != "" || h.app.project != nil || len(h.directoryEntries(parent)) != 0 {
		t.Fatalf("a failed command left %v (created %q)", h.directoryEntries(parent), n.created)
	}
	// The user can fix the form and try again: the window is still usable.
	if h.pageHit("Create").Disabled {
		t.Fatal("Create stays disabled after a failure")
	}
}

func TestNewProjectCancelStopsARunningCommand(t *testing.T) {
	parent := t.TempDir()
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, commandGeneratorPlugin(t))
	useHelperExecutable(t, h)
	h.openNewProjectSheet()
	h.chooseGenerator("Blocking", "dev.lithe.test.scaffold/blocking")
	n := &h.app.newProject
	n.parent, n.name = parent, "demo"
	h.app.invalidator.Invalidate()
	h.awaitValidForm()
	// The command blocks by design, so the click must not wait for every task.
	point := center(h.pageHit("Create").Bounds)
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	h.await("the command's output", func() bool { return n.busy && h.shows("ready") })
	if !h.shows("Step 1 of 1") {
		t.Fatal("the run does not show its step")
	}
	point = center(h.pageHit("Cancel").Bounds)
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	h.await("the cancelled run to close the sheet", func() bool { return !n.open })
	h.settle()
	if names := h.directoryEntries(parent); len(names) != 0 || h.app.project != nil {
		t.Fatalf("cancelling left %v", names)
	}
}

func TestNewProjectGeneratorKeepsTheCreatedDirectoryWhenGitFails(t *testing.T) {
	parent := t.TempDir()
	h := newGeneratorHarness(t, &failingNewProjectGitKernel{&testKernel{Client: core.NewClient()}}, fixtureGeneratorPlugin(t))
	h.openNewProjectSheet()
	h.chooseGenerator("App", "dev.lithe.fixture.project-generator/app")
	n := &h.app.newProject
	n.parent, n.name, n.git = parent, "demo", true
	h.app.invalidator.Invalidate()
	h.awaitValidForm()
	h.clickNamed("Create")
	h.await("the Git failure", func() bool { return !n.busy && n.created != "" })
	path := filepath.Join(parent, "demo")
	if n.created != path || n.err == "" || h.app.project != nil {
		t.Fatalf("created = %q, err = %q", n.created, n.err)
	}
	if _, err := os.Stat(filepath.Join(path, "README.md")); err != nil {
		t.Fatalf("the generated project was not kept: %v", err)
	}
	h.clickNamed("Open Created Project")
	if h.app.project == nil || h.app.project.root != path {
		t.Fatal("could not open the kept project")
	}
}

func TestNewProjectToolFieldListsInstallationsAndPinsTheChoice(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(generatorFixtures, "project-generator-tool-field.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	path, _ := filepath.Abs(generatorFixtures)
	plugin := pluginservice.GeneratorPlugin{PluginID: "dev.lithe.fixture.project-generator-tool-field", Version: "1.0.0", Path: path, Enabled: true, Manifest: data}
	parent := t.TempDir()
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, plugin)
	h.app.projectToolLists = func(_ context.Context, tools []string) (map[string]toolList, error) {
		lists := map[string]toolList{}
		for _, tool := range tools {
			lists[tool] = toolList{Default: "/opt/python-3.12", Installations: []toolInstall{
				{ProjectToolInstallation: core.ProjectToolInstallation{Home: "/opt/python-3.10", Executable: "/opt/python-3.10/bin/python3", Version: "3.10.14"}, Provider: "host:system"},
				{ProjectToolInstallation: core.ProjectToolInstallation{Home: "/opt/python-3.12", Executable: "/opt/python-3.12/bin/python3", Version: "3.12.4"}, Provider: "host:system"},
			}}
		}
		return lists, nil
	}
	h.openNewProjectSheet()
	var entry *projectChoice
	for index := range h.app.newProject.choices {
		if choice := &h.app.newProject.choices[index]; choice.entry != nil && choice.entry.Generator.ID == "python-app" {
			entry = choice
		}
	}
	if entry == nil {
		t.Fatalf("python-app is not listed: %+v", h.app.newProject.choices)
	}
	h.chooseGenerator(entry.name, entry.key)
	form := h.app.newProject.forms[entry.key]
	field := form.byID["python"]
	if field == nil || field.text != "/opt/python-3.12" {
		t.Fatalf("Core's newest installation was not selected: %+v", field)
	}
	if len(field.state.Installations) != 2 || field.state.Installations[0].MeetsMinimum {
		t.Fatalf("installations = %+v", field.state.Installations)
	}
	n := &h.app.newProject
	n.parent, n.name = parent, "pinned"
	// The fixture's command step would run uv; this test is about the tool pin.
	h.clickNamed("Create a virtual environment")
	h.awaitValidForm()
	h.clickNamed("Create")
	h.awaitProjectOpen()
	pin, err := os.ReadFile(filepath.Join(parent, "pinned", ".lithe", "toolchains", "local.json"))
	if err != nil || !strings.Contains(string(pin), "/opt/python-3.12") {
		t.Fatalf("the project's tool pin = %q, %v", pin, err)
	}
}
