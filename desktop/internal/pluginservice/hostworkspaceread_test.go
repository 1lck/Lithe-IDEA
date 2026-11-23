package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// diskReadWorkbench delegates reads to the actual Core, with only the UI surface replaced.
type diskReadWorkbench struct {
	*fakeWorkbench
	kernel *core.Client
}

func (w diskReadWorkbench) ReadDirectory(ctx context.Context, request core.WorkspaceDirectoryRequest) (core.WorkspaceDirectoryPage, error) {
	return w.kernel.ReadWorkspaceDirectory(ctx, request)
}

func (w diskReadWorkbench) StatEntry(ctx context.Context, root, path string) (core.WorkspaceStat, error) {
	return w.kernel.StatWorkspaceEntry(ctx, root, path)
}

func (w diskReadWorkbench) ReadFile(ctx context.Context, root, path string, maximumBytes *int) (core.WorkspaceFileRead, error) {
	return w.kernel.ReadWorkspaceFile(ctx, root, path, maximumBytes)
}

func (w diskReadWorkbench) FindFiles(ctx context.Context, request core.WorkspaceFindRequest) (core.WorkspaceFindPage, error) {
	return w.kernel.FindWorkspaceFiles(ctx, request)
}

func (w diskReadWorkbench) FindText(ctx context.Context, request core.WorkspaceFindRequest) (core.WorkspaceFindPage, error) {
	return w.kernel.FindWorkspaceText(ctx, request)
}

func (w diskReadWorkbench) PlanWatch(ctx context.Context, root, path string, recursive bool) (core.WorkspaceWatchPlan, error) {
	return w.kernel.PlanWorkspaceWatch(ctx, root, path, recursive)
}

func (w diskReadWorkbench) FilterWatchEvents(ctx context.Context, _ string, plan core.WorkspaceWatchPlan, paths []string, rescan bool) (core.WorkspaceWatchEvents, error) {
	return w.kernel.FilterWorkspaceWatchEvents(ctx, plan, paths, rescan)
}

func TestWorkspaceReadsUseCoreAndPreservePublicResourceEnvelopes(t *testing.T) {
	service := openHostService(t)
	if err := service.AttachWorkbench(diskReadWorkbench{&fakeWorkbench{}, core.NewClient()}); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("disk"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "binary"), []byte{0, 255}, 0o600); err != nil {
		t.Fatal(err)
	}
	workspace := service.Contexts.Open(root)
	t.Cleanup(func() { service.Contexts.Close(workspace.Path) })
	rootID := service.Contexts.RootID("a", workspace.Path)
	call := func(plugin, method, path, extra string) (map[string]json.RawMessage, *pluginhost.Failure) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"context": workspace.ContextRef, "resource": Resource{rootID, path}})
		if extra != "" {
			body = append(body[:len(body)-1], []byte(","+extra+"}")...)
		}
		result, refusal := respond(t, service, plugin, "workspace/"+method, string(body))
		var value map[string]json.RawMessage
		if refusal == nil {
			if err := json.Unmarshal(result, &value); err != nil {
				t.Fatal(err)
			}
		}
		return value, refusal
	}
	file, refusal := call("a", "readFile", "a.txt", "")
	if refusal != nil || string(file["text"]) != `"disk"` || string(file["source"]) != `"disk"` || file["path"] != nil {
		t.Fatalf("file = %s, %+v", file, refusal)
	}
	var resource Resource
	if err := json.Unmarshal(file["resource"], &resource); err != nil || resource != (Resource{rootID, "a.txt"}) {
		t.Fatalf("resource = %+v, %v", resource, err)
	}
	binary, refusal := call("a", "readFile", "binary", "")
	if refusal != nil || string(binary["base64"]) != `"AP8="` || binary["text"] != nil {
		t.Fatalf("binary = %s, %+v", binary, refusal)
	}
	stat, refusal := call("a", "stat", "a.txt", "")
	if refusal != nil || string(stat["size"]) != "4" || stat["path"] != nil {
		t.Fatalf("stat = %s, %+v", stat, refusal)
	}
	page, refusal := call("a", "readDirectory", "", `"limit":1`)
	var entries []struct {
		Name     string
		Resource Resource
	}
	if err := json.Unmarshal(page["entries"], &entries); err != nil || refusal != nil || len(entries) != 1 || entries[0].Resource != (Resource{rootID, "a.txt"}) || string(page["nextCursor"]) == "null" {
		t.Fatalf("directory = %s, %+v, %v", page, refusal, err)
	}
	for _, test := range []struct{ method, path, extra, code string }{
		{"readFile", "missing", "", CodeNotFound},
		{"readFile", "../outside", "", codeInvalidParams},
		{"readFile", "a.txt", `"maximumBytes":131073`, codeInvalidParams},
	} {
		if _, refusal := call("a", test.method, test.path, test.extra); refusal == nil || refusal.Code != test.code {
			t.Fatalf("%+v = %+v", test, refusal)
		}
	}
	if _, refusal := call("b", "readFile", "a.txt", ""); refusal == nil || refusal.Code != codeInvalidParams {
		t.Fatalf("another plugin's root = %+v", refusal)
	}
	service.Contexts.Close(workspace.Path)
	if _, refusal := call("a", "stat", "a.txt", ""); refusal == nil || refusal.Code != CodeContextExpired {
		t.Fatalf("closed context = %+v", refusal)
	}
}

func TestWorkspaceReadsAreAdvertisedOnlyWithAnAttachedReadHost(t *testing.T) {
	service := openHostService(t)
	methods := []string{methodWorkspaceReadDirectory, methodWorkspaceStat, methodWorkspaceReadFile, methodWorkspaceFindFiles, methodWorkspaceFindText, methodWorkspaceWatch}
	if grants := pluginhost.GrantServices(methods, service.HostServices); len(grants) != 0 {
		t.Fatalf("windowless grants = %v", grants)
	}
	if err := service.AttachWorkbench(diskReadWorkbench{&fakeWorkbench{}, core.NewClient()}); err != nil {
		t.Fatal(err)
	}
	if grants := pluginhost.GrantServices(methods, service.HostServices); len(grants) != len(methods) {
		t.Fatalf("attached grants = %v", grants)
	}
}
