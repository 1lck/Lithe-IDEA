package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

func TestWelcomeCreatesEmptyProjectWithGitThroughCore(t *testing.T) {
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &gitKernel{Client: core.NewClient()}, []string{"en-US"})
	h.click(center(h.hit(welcomeNew)))
	if !h.app.newProject.open || !h.shows("Empty Project") {
		t.Fatal("the welcome action did not open New Project")
	}
	if !h.shows("Get more languages and frameworks from plugins…") {
		t.Fatal("the marketplace entry is missing its localized label")
	}
	h.app.newProject.parent.SetText(parent)
	h.app.newProject.name.SetText("hello project")
	h.app.invalidator.Invalidate()
	h.settle()
	h.click(center(h.hit(newProjectGit)))
	h.click(center(h.hit(newProjectCreate)))
	destination := filepath.Join(parent, "hello project")
	if h.app.newProject.open || h.app.project == nil || h.app.project.root != destination {
		t.Fatalf("new project open = %v, project = %+v", h.app.newProject.open, h.app.project)
	}
	info, err := os.Stat(filepath.Join(destination, ".git"))
	if err != nil || !info.IsDir() {
		t.Fatalf("Git directory = %v, error = %v", info, err)
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

type failingNewProjectGitKernel struct{ *testKernel }

func (k *failingNewProjectGitKernel) InitializeGit(context.Context, string) error {
	return errors.New("fixture Git initialization failed")
}

func TestNewProjectGitFailureKeepsDirectoryAndOffersToOpen(t *testing.T) {
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &failingNewProjectGitKernel{&testKernel{Client: core.NewClient()}}, []string{"en-US"})
	h.click(center(h.hit(welcomeNew)))
	h.app.newProject.parent.SetText(parent)
	h.app.newProject.name.SetText("created")
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
	h.click(center(h.hit(newProjectCreate)))
	if h.app.project == nil || h.app.project.root != path {
		t.Fatal("could not open the created directory")
	}
}

func TestNewProjectEscapeRestoresWelcomeFocus(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.click(center(h.hit(welcomeNew)))
	if h.driver.Snapshot().Focused != newProjectSearch {
		t.Fatal("search did not receive focus")
	}
	if err := h.driver.Key(ui.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.newProject.open || h.driver.Snapshot().Focused != welcomeNew {
		t.Fatal("Escape did not close the dialog and restore focus")
	}
}

func TestNewProjectSearchUsesCoreAndKeepsSelectedDetails(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.click(center(h.hit(welcomeNew)))
	h.app.newProject.search.SetText("unmatch-xyz")
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.shows("Empty Project") || !h.shows("A basic project with a free structure.") {
		t.Fatal("search should hide the unmatched row while keeping the selected form")
	}
	h.click(center(h.hit(newProjectSearchClear)))
	if !h.shows("Empty Project") || h.driver.Snapshot().Focused != newProjectSearch {
		t.Fatalf("clearing search: row=%v focus=%v want=%v query=%q visible=%v", h.shows("Empty Project"), h.driver.Snapshot().Focused, newProjectSearch, h.app.newProject.search.Text(), h.app.newProject.searchVisible)
	}
}

type delayedNewProjectSearchKernel struct {
	*testKernel
	started, release chan struct{}
}

func (k *delayedNewProjectSearchKernel) RankNames(ctx context.Context, query string, candidates []core.RankCandidate) ([]int, error) {
	if query == "unmatch-xyz" {
		close(k.started)
		<-k.release // Deliberately returns an old result after cancellation.
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
	h.click(center(h.hit(welcomeNew)))
	h.app.newProject.search.SetText("unmatch-xyz")
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
	h.app.newProject.search.SetText("")
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
	h.click(center(h.hit(welcomeNew)))
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
	h.click(center(h.hit(welcomeNew)))
	if err := h.driver.Click(600, 400); err != nil {
		t.Fatal(err)
	}
	if !h.app.newProject.open || h.app.project != nil {
		t.Fatal("an empty area inside the sheet dismissed it or reached the background")
	}
	for range 8 {
		if err := h.driver.Key(ui.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
		focus := h.driver.Snapshot().Focused
		if focus == welcomeNew || focus == welcomeOpen || focus == welcomeMore {
			t.Fatalf("keyboard focus escaped the sheet to %v", focus)
		}
	}
}

type blockedNewProjectKernel struct {
	*testKernel
	started chan struct{}
}

func (k *blockedNewProjectKernel) CheckProjectName(ctx context.Context, _ string) (core.ProjectNameProblem, error) {
	close(k.started)
	<-ctx.Done()
	return "", ctx.Err()
}

func TestClosingWindowCancelsPendingNewProject(t *testing.T) {
	kernel := &blockedNewProjectKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openNewProject(surfaceButton)
	h.app.newProject.parent.SetText(t.TempDir())
	h.app.newProject.name.SetText("not-created")
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
	h.app.newProject.parent.SetText(parent)
	h.app.newProject.name.SetText("not-created")
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
	h.app.newProject.parent.SetText(parent)
	h.app.newProject.name.SetText("created")
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
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.click(center(h.hit(welcomeNew)))
	parent := t.TempDir()
	if err := h.driver.QueueOpenDirectory(parent, nil); err != nil {
		t.Fatal(err)
	}
	h.click(center(h.hit(newProjectChoose)))
	if h.app.newProject.parent.Text() != parent {
		t.Fatal("folder picker did not set the location")
	}
	h.click(center(h.hit(newProjectGitText)))
	if !h.app.newProject.git {
		t.Fatal("clicking the Git label did not select it")
	}
}

func TestNewProjectMarketplaceEntryInvokesPluginSettings(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	h.click(center(h.hit(welcomeNew)))
	h.click(center(h.hit(newProjectMore)))
	log.mu.Lock()
	defer log.mu.Unlock()
	for _, event := range log.events {
		if event.Event == "app.action.performed" && event.Fields["action"] == "settings.open" {
			return
		}
	}
	t.Fatal("marketplace entry did not invoke plugin settings")
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
