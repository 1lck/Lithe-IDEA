package pluginservice

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestRemotePluginFilesUseTheAuthorizedWorkspaceBinding(t *testing.T) {
	service := openHostService(t)
	binding := core.NewRemoteWorkspace(t.TempDir(), "/home/dev/remote", nil)
	binding.Attach("live-session")
	workspace := service.Contexts.OpenRemote(binding, "project", "c-test", core.RemotePlatform{OS: "linux", Arch: "x86_64"}, nil)
	t.Cleanup(service.Contexts.CloseAll)
	const plugin = "dev.lithe.test.remote-files"
	rootID := service.Contexts.RootID(plugin, workspace.Path)
	ref, err := json.Marshal(workspace.ContextRef)
	if err != nil {
		t.Fatal(err)
	}
	params := `{"context":` + string(ref) + `,"resource":{"rootID":"` + rootID + `","path":"src/main.txt"},"maximumBytes":64}`
	calls := 0
	next := func() (json.RawMessage, error) { return json.RawMessage(`{"text":"from host"}`), nil }
	service.kernel.(*fakeKernel).pluginFile = func(ctx context.Context, request core.PluginFileRequest) (json.RawMessage, error) {
		calls++
		if core.RemoteWorkspaceOf(ctx) != binding || request.RootID != rootID || request.Generation != workspace.Generation ||
			request.Path != "src/main.txt" || request.Operation.Kind != "readFile" || request.Operation.MaximumBytes == nil || *request.Operation.MaximumBytes != 64 {
			t.Fatalf("incorrect host dispatch: %+v", request)
		}
		return next()
	}

	result, refusal := respond(t, service, plugin, "workspace/readFile", params)
	if refusal != nil || string(result) != `{"text":"from host"}` {
		t.Fatalf("readFile = %s, %+v", result, refusal)
	}
	if _, refusal := respond(t, service, "dev.lithe.test.another", "workspace/readFile", params); refusal == nil || refusal.Code != "plugin.host.invalidParams" || calls != 1 {
		t.Fatalf("foreign resource = %+v, dispatched %d times", refusal, calls)
	}
	next = func() (json.RawMessage, error) {
		return nil, &core.Error{Code: core.CodeProcessFailed, Details: `{"remoteCode":"TOO_LARGE"}`}
	}
	if _, refusal := respond(t, service, plugin, "workspace/readFile", params); refusal == nil || refusal.Code != "plugin.host.limitExceeded" {
		t.Fatalf("oversize request = %+v", refusal)
	}
	next = func() (json.RawMessage, error) {
		binding.Attach("replacement-session")
		return json.RawMessage(`{"text":"from old session"}`), nil
	}
	if result, refusal := respond(t, service, plugin, "workspace/readFile", params); refusal == nil || refusal.Code != "plugin.host.remoteDisconnected" || result != nil {
		t.Fatalf("old session result = %s, %+v", result, refusal)
	}
	next = func() (json.RawMessage, error) {
		service.Contexts.Close(workspace.Path)
		return json.RawMessage(`{"text":"from closed context"}`), nil
	}
	if result, refusal := respond(t, service, plugin, "workspace/readFile", params); refusal == nil || refusal.Code != "plugin.host.contextExpired" || result != nil {
		t.Fatalf("closed context result = %s, %+v", result, refusal)
	}
}
