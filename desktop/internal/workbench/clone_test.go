package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

func TestWelcomeClonesRepositoryThroughRealCore(t *testing.T) {
	source := newTestRepository(t)
	parent := t.TempDir()
	h := newHarnessWithLanguages(t, &gitKernel{Client: core.NewClient()}, []string{"en-US"})
	h.click(center(h.hit(welcomeMore)))
	h.click(center(h.hit(welcomeClone)))
	if !h.app.clone.open || !h.shows("Clone Repository") {
		t.Fatal("the welcome action did not open the clone dialog")
	}
	h.app.clone.source.SetText(source)
	h.app.clone.parent.SetText(parent)
	h.app.clone.name.SetText("cloned project")
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickShared("desktop.clone.submit")
	destination := filepath.Join(parent, "cloned project")
	if h.app.clone.open || h.app.project == nil || h.app.project.root != destination {
		t.Fatalf("clone dialog open = %v, project = %+v", h.app.clone.open, h.app.project)
	}
	content, err := os.ReadFile(filepath.Join(destination, "changed.txt"))
	if err != nil || string(content) != "first\n" {
		t.Fatalf("cloned committed content = %q, error = %v", content, err)
	}
}

func TestWelcomeMoreMenuClosesOnEscape(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.click(center(h.hit(welcomeMore)))
	if got := h.driver.Snapshot().Focused; got != welcomeClone {
		t.Fatalf("opening the more menu focused %v, want the clone action", got)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.moreOpen {
		t.Fatal("the welcome more menu remained open after Escape")
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMore {
		t.Fatalf("closing the more menu focused %v, want the more button", got)
	}
}

func TestCloneDirectoryPickerUsesSelectedDirectory(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.openClone(surfaceButton)
	h.app.invalidator.Invalidate()
	h.settle()
	want := t.TempDir()
	if err := h.driver.QueueOpenDirectory(want, nil); err != nil {
		t.Fatal(err)
	}
	h.clickShared("desktop.clone.choose")
	if got := h.app.clone.parent.Text(); got != want {
		t.Fatalf("selected directory = %q, want %q", got, want)
	}
}

func TestCloneDialogCanBeOpenedAndDismissedByKeyboard(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.click(center(h.hit(welcomeMore)))
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if !h.app.clone.open || h.focusedName() != i18n.Shared(h.app.language(), "desktop.clone.source") {
		t.Fatalf("clone open = %v, focused = %q", h.app.clone.open, h.focusedName())
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.clone.open {
		t.Fatal("Escape did not dismiss the clone dialog")
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMore {
		t.Fatalf("closing clone focused %v, want the welcome more button", got)
	}
}

type failingCloneKernel struct{ *testKernel }

func (k *failingCloneKernel) GitClone(context.Context, string, string, string) error {
	return errors.New("fixture failure containing fixture-private-value")
}

func TestCloneFailureKeepsFieldsAndShowsError(t *testing.T) {
	h := newHarnessWithLanguages(t, &failingCloneKernel{&testKernel{Client: core.NewClient()}}, []string{"en-US"})
	h.app.openClone(surfaceButton)
	h.app.clone.source.SetText("https://example.invalid/project.git")
	h.app.clone.parent.SetText(t.TempDir())
	h.app.clone.name.SetText("project")
	h.app.submitClone()
	h.settle()
	if !h.app.clone.open || h.app.clone.busy || h.app.clone.err == "" || h.app.clone.name.Text() != "project" || h.app.project != nil {
		t.Fatalf("clone failure lost the draft or opened a project: %+v", h.app.clone)
	}
	if strings.Contains(h.app.clone.err, "fixture-private-value") {
		t.Fatal("clone failure exposed a credential from Git output")
	}
}

func TestCloneRejectsPathEscapeBeforeCallingCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.openClone(surfaceMenu)
	h.app.clone.source.SetText("https://example.invalid/project.git")
	h.app.clone.parent.SetText(t.TempDir())
	h.app.clone.name.SetText(filepath.Join("..", "outside"))
	h.app.submitClone()
	if h.app.clone.busy || h.app.clone.err == "" {
		t.Fatalf("invalid path was accepted: %+v", h.app.clone)
	}
}

func TestCloneDialogIsVisibleOnItsFirstFrame(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.openClone(surfaceButton)
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	snapshot := h.driver.Snapshot()
	for _, primitive := range snapshot.Primitives {
		if primitive.Layer > 0 && primitive.Bounds.Width == float32(snapshot.Width) &&
			primitive.Bounds.Height == float32(snapshot.Height) && primitive.Color.Alpha > 0 {
			return
		}
	}
	t.Fatal("the clone dialog's first frame has no visible backdrop")
}

type cancellableCloneKernel struct {
	*testKernel
	started chan struct{}
}

func (k *cancellableCloneKernel) GitClone(ctx context.Context, _, _, _ string) error {
	close(k.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestCloneCancellationWaitsForCoreAndDoesNotOpenProject(t *testing.T) {
	kernel := &cancellableCloneKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openClone(surfaceMenu)
	h.app.clone.source.SetText("https://example.invalid/project.git")
	h.app.clone.parent.SetText(t.TempDir())
	h.app.clone.name.SetText("project")
	h.app.submitClone()
	select {
	case <-kernel.started:
	case <-time.After(5 * time.Second):
		t.Fatal("clone did not reach Core")
	}
	h.app.cancelClone()
	if !h.app.clone.busy || !h.app.clone.cancelling {
		t.Fatal("cancellation did not wait for the running Core operation")
	}
	h.settle()
	if h.app.clone.open || h.app.project != nil {
		t.Fatal("cancelled clone remained open or opened a project")
	}
}

func TestClosingWindowCancelsClone(t *testing.T) {
	kernel := &cancellableCloneKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{})}
	h := newHarness(t, kernel)
	h.app.openClone(surfaceMenu)
	h.app.clone.source.SetText("https://example.invalid/project.git")
	h.app.clone.parent.SetText(t.TempDir())
	h.app.clone.name.SetText("project")
	h.app.submitClone()
	select {
	case <-kernel.started:
	case <-time.After(5 * time.Second):
		t.Fatal("clone did not reach Core")
	}
	h.app.closed()
	h.settle()
	if h.app.clone.open || h.app.project != nil {
		t.Fatal("closing the window left the clone active or opened a project")
	}
}
