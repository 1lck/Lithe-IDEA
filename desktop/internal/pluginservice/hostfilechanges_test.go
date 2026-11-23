package pluginservice

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fakeFileChanges is a window that also saves documents and changes files; it records each
// call as one line and answers with err.
type fakeFileChanges struct {
	*fakeWorkbench
	mu    sync.Mutex
	calls []string
	err   error
}

func (f *fakeFileChanges) record(format string, args ...any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, fmt.Sprintf(format, args...))
	return f.err
}

func (f *fakeFileChanges) SaveDocument(_ context.Context, root, id string, expectedVersion *int) (DocumentSummary, error) {
	version := -1
	if expectedVersion != nil {
		version = *expectedVersion
	}
	return DocumentSummary{DocumentID: id}, f.record("save %s %s %d", root, id, version)
}

func (f *fakeFileChanges) SaveDocumentAs(_ context.Context, root, id, target string) (DocumentSummary, error) {
	return DocumentSummary{DocumentID: "new"}, f.record("saveAs %s %s %s", root, id, target)
}

func (f *fakeFileChanges) CloseDocument(_ context.Context, root, id string) error {
	return f.record("close %s %s", root, id)
}

func (f *fakeFileChanges) CreateEntry(_ context.Context, root string, entry EntryCreation) error {
	text, link := "-", "-"
	if entry.Text != nil {
		text = *entry.Text
	}
	if entry.LinkTarget != nil {
		link = *entry.LinkTarget
	}
	return f.record("create %s %s %s %s %s", root, entry.Path, entry.Kind, text, link)
}

func (f *fakeFileChanges) RenameEntry(_ context.Context, root, from, to string) error {
	return f.record("rename %s %s %s", root, from, to)
}

func (f *fakeFileChanges) CopyEntry(_ context.Context, root, from, to string) error {
	return f.record("copy %s %s %s", root, from, to)
}

func (f *fakeFileChanges) TrashEntry(_ context.Context, root, path string) error {
	return f.record("trash %s %s", root, path)
}

func openFileChangeService(t *testing.T) (*Service, *fakeFileChanges, WorkspaceContext, string) {
	t.Helper()
	service, err := Open(&notifyKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	host := &fakeFileChanges{fakeWorkbench: &fakeWorkbench{consent: true}}
	if err := service.AttachWorkbench(host); err != nil {
		t.Fatal(err)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workspace := service.Contexts.Open(root)
	return service, host, workspace, service.Contexts.RootID("a", workspace.Path)
}

// Each method reaches the window with the workspace's folder and the paths as the plugin named
// them below it; Core resolves them.
func TestFileChangesReachTheWindowWithPathsBelowTheRoot(t *testing.T) {
	service, host, workspace, rootID := openFileChangeService(t)
	resource := func(path string) string { return `{"rootID":"` + rootID + `","path":"` + path + `"}` }
	root := workspace.Path
	for _, call := range []struct {
		method, params, result, recorded string
	}{
		{"documents/save", `"documentID":"d1","expectedVersion":4`, `{"document":{"documentID":"d1"`, "save " + root + " d1 4"},
		{"documents/saveAs", `"documentID":"d1","target":` + resource("out/a.txt"), `{"document":{"documentID":"new"`, "saveAs " + root + " d1 out/a.txt"},
		{"documents/close", `"documentID":"d1"`, `null`, "close " + root + " d1"},
		{"workspace/create", `"resource":` + resource("a.txt") + `,"kind":"file","text":"hi"`, `{"kind":"file","resource":` + resource("a.txt") + `}`, "create " + root + " a.txt file hi -"},
		{"workspace/create", `"resource":` + resource("lib") + `,"kind":"symlink","linkTarget":"../shared/lib"`, `{"kind":"symlink","resource":` + resource("lib") + `}`, "create " + root + " lib symlink - ../shared/lib"},
		{"workspace/rename", `"resource":` + resource("a.txt") + `,"target":` + resource("b/a.txt"), `{"resource":` + resource("b/a.txt") + `}`, "rename " + root + " a.txt b/a.txt"},
		{"workspace/copy", `"resource":` + resource("b") + `,"target":` + resource("c"), `{"resource":` + resource("c") + `}`, "copy " + root + " b c"},
		{"workspace/trash", `"resource":` + resource("c"), `null`, "trash " + root + " c"},
	} {
		result, refusal := respond(t, service, "a", call.method, `{`+contextJSONOf(workspace)+`,`+call.params+`}`)
		if refusal != nil || !strings.HasPrefix(string(result), call.result) {
			t.Fatalf("%s = %s %+v", call.method, result, refusal)
		}
		if last := host.calls[len(host.calls)-1]; last != call.recorded {
			t.Fatalf("%s reached the window as %q, want %q", call.method, last, call.recorded)
		}
	}
}

// A resource or target in a root the plugin was not given is refused before the window sees it,
// and the window's refusal reaches the plugin with its code.
func TestFileChangesRefuseAnotherRootAndPassTheWindowsCode(t *testing.T) {
	service, host, workspace, rootID := openFileChangeService(t)
	for _, params := range []string{
		`"resource":{"rootID":"other","path":"a.txt"},"kind":"directory"`,
		`"resource":{"rootID":"` + rootID + `","path":"a.txt"},"target":{"rootID":"other","path":"b.txt"}`,
	} {
		method := "workspace/create"
		if strings.Contains(params, `"target"`) {
			method = "workspace/copy"
		}
		_, refusal := respond(t, service, "a", method, `{`+contextJSONOf(workspace)+`,`+params+`}`)
		if refusal == nil || refusal.Code != codeInvalidParams {
			t.Fatalf("%s in another root = %+v", method, refusal)
		}
	}
	if len(host.calls) != 0 {
		t.Fatalf("a refused change reached the window: %v", host.calls)
	}
	host.err = &HostError{Code: CodeAlreadyExists, Message: "The target exists."}
	_, refusal := respond(t, service, "a", "workspace/create", `{`+contextJSONOf(workspace)+`,"resource":{"rootID":"`+rootID+`","path":"a"},"kind":"directory"}`)
	if refusal == nil || refusal.Code != CodeAlreadyExists {
		t.Fatalf("existing target = %+v", refusal)
	}
}

func TestChangeErrorMapsCoreCodes(t *testing.T) {
	for _, test := range []struct {
		err  error
		code string
	}{
		{&core.Error{Code: core.CodeEntryExists, Message: "Entry exists"}, CodeAlreadyExists},
		{&core.Error{Code: core.CodeEntryNotFound, Message: "Entry does not exist"}, CodeNotFound},
		{&core.Error{Code: core.CodeInvalidRequest, Message: "The target cannot be inside the entry"}, codeInvalidParams},
		{&core.Error{Code: core.CodePermissionDenied, Message: "Entry is outside the workspace"}, codeInvalidParams},
		{&core.Error{Code: core.CodeUnknown, Message: "Could not create the entry"}, CodeFailed},
		{errors.New("disk full"), CodeFailed},
	} {
		var mapped *HostError
		if !errors.As(ChangeError(test.err), &mapped) || mapped.Code != test.code {
			t.Fatalf("%v mapped to %v, want %s", test.err, ChangeError(test.err), test.code)
		}
	}
	refusal := &HostError{Code: CodeBusy, Message: "busy"}
	if ChangeError(refusal) != refusal || !errors.Is(ChangeError(context.Canceled), context.Canceled) || ChangeError(nil) != nil {
		t.Fatal("a host error, a cancellation or no error changed")
	}
	cancelled := &core.Error{Code: core.CodeCancelled}
	if ChangeError(cancelled) != cancelled {
		t.Fatal("Core's cancellation is not passed as a cancellation")
	}
}
