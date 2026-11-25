package workbench

import (
	"context"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestPluginWorkspaceReadsUseDiskWhileTheLiveDocumentIsDirty(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, d := openNote(t, h, "alpha")
	pluginEdit(t, h, root, d, "ALPHA")
	w := pluginWorkbench{app: h.app}
	file, err := callOnWindow(h, "read disk", func(ctx context.Context) (core.WorkspaceFileRead, error) {
		return w.ReadFile(ctx, root, "note.txt", nil)
	})
	if err != nil || file.Text == nil || *file.Text != "alpha" || file.Source != "disk" || file.IsTruncated {
		t.Fatalf("read = %+v, %v", file, err)
	}
	if text, _ := d.view.Text(); string(text) != "ALPHA" || !d.dirty() {
		t.Fatal("reading disk changed the live document")
	}
	search, err := callOnWindow(h, "search disk", func(ctx context.Context) (core.WorkspaceFindPage, error) {
		return w.FindText(ctx, core.WorkspaceFindRequest{Root: root, Pattern: "alpha", CaseSensitive: true})
	})
	if err != nil || len(search.Matches) != 1 || search.Matches[0].Preview != "alpha" || search.Source != "disk" {
		t.Fatalf("search = %+v, %v", search, err)
	}
	plan, err := callOnWindow(h, "plan watch", func(ctx context.Context) (core.WorkspaceWatchPlan, error) {
		return w.PlanWatch(ctx, root, "note.txt", false)
	})
	if err != nil {
		t.Fatal(err)
	}
	events, err := callOnWindow(h, "project watch event", func(ctx context.Context) (core.WorkspaceWatchEvents, error) {
		return w.FilterWatchEvents(ctx, root, plan, []string{"note.txt", "other.txt"}, false)
	})
	if err != nil || len(events.ChangedPaths) != 1 || events.ChangedPaths[0] != "note.txt" || events.RequiresRescan {
		t.Fatalf("events = %+v, %v", events, err)
	}
	stat, err := callOnWindow(h, "stat disk", func(ctx context.Context) (core.WorkspaceStat, error) {
		return w.StatEntry(ctx, root, "note.txt")
	})
	if err != nil || stat.Kind != "file" || stat.Size != 5 {
		t.Fatalf("stat = %+v, %v", stat, err)
	}
	page, err := callOnWindow(h, "list disk", func(ctx context.Context) (core.WorkspaceDirectoryPage, error) {
		return w.ReadDirectory(ctx, core.WorkspaceDirectoryRequest{Root: root})
	})
	if err != nil || len(page.Entries) != 1 || page.Entries[0].Path != "note.txt" {
		t.Fatalf("page = %+v, %v", page, err)
	}
	_, err = callOnWindow(h, "read other workspace", func(ctx context.Context) (core.WorkspaceFileRead, error) {
		return w.ReadFile(ctx, root+"-other", "note.txt", nil)
	})
	if hostErrorCode(err) != pluginservice.CodeContextExpired {
		t.Fatalf("other workspace = %v", err)
	}
	_, err = callOnWindow(h, "missing file", func(ctx context.Context) (core.WorkspaceStat, error) {
		return w.StatEntry(ctx, root, "missing")
	})
	if hostErrorCode(err) != pluginservice.CodeNotFound {
		t.Fatalf("missing = %v", err)
	}
}

// closingWorkspaceReadKernel waits for cancellation instead of returning file
// contents. The window event closes the project only after its read has started.
type closingWorkspaceReadKernel struct {
	*testKernel
	closeProject func()
}

func (k *closingWorkspaceReadKernel) ReadWorkspaceFile(ctx context.Context, _, _ string, _ *int) (core.WorkspaceFileRead, error) {
	k.closeProject()
	<-ctx.Done() // callOnWindow supplies an eight-second request deadline.
	return core.WorkspaceFileRead{}, ctx.Err()
}

func (k *closingWorkspaceReadKernel) FindWorkspaceText(ctx context.Context, _ core.WorkspaceFindRequest) (core.WorkspaceFindPage, error) {
	k.closeProject()
	<-ctx.Done() // callOnWindow supplies an eight-second request deadline.
	return core.WorkspaceFindPage{}, ctx.Err()
}

func TestPluginWorkspaceReadsCancelWhenTheProjectCloses(t *testing.T) {
	checkWorkspaceCloseCancellation(t, false)
}

func TestPluginWorkspaceSearchCancelsWhenTheProjectCloses(t *testing.T) {
	checkWorkspaceCloseCancellation(t, true)
}

func checkWorkspaceCloseCancellation(t *testing.T, search bool) {
	t.Helper()
	kernel := &closingWorkspaceReadKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	root := t.TempDir()
	h.open(root)
	h.settle()
	kernel.closeProject = func() {
		h.app.post(func(a *App) { a.closeProject() })
	}
	_, err := callOnWindow(h, "close project during disk operation", func(ctx context.Context) (bool, error) {
		w := pluginWorkbench{app: h.app}
		if search {
			_, err := w.FindText(ctx, core.WorkspaceFindRequest{Root: root, Pattern: "input"})
			return false, err
		}
		_, err := w.ReadFile(ctx, root, "input", nil)
		return false, err
	})
	if hostErrorCode(err) != pluginservice.CodeContextExpired || h.app.project != nil {
		t.Fatalf("closed project read = %v, project = %p", err, h.app.project)
	}
}
