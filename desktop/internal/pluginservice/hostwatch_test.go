package pluginservice

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestRemoteWorkspaceWatchKeepsSubscriptionOwnershipAcrossAttachments(t *testing.T) {
	kernel := &buildWatchKernel{events: make(chan buildWatchNotification, 8)}
	kernel.pluginFile = func(_ context.Context, _ core.PluginFileRequest) (json.RawMessage, error) {
		return json.RawMessage(`{"path":"src","directory":true}`), nil
	}
	kernel.pluginWatch = core.NewClient().PluginWatchChanges
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	binding := core.NewRemoteWorkspace(t.TempDir(), "/home/dev/work", nil)
	binding.Attach("live")
	workspace := service.Contexts.OpenRemote(binding, "project", "c-test", core.RemotePlatform{OS: "linux", Arch: "x86_64"}, nil)
	t.Cleanup(service.Contexts.CloseAll)
	const plugin, session = "dev.lithe.test.watch", "session-test-watch"
	runningActionSession(service, plugin, session)
	caller := pluginhost.Caller{PluginID: plugin, SessionID: session}
	root := service.Contexts.RootID(plugin, workspace.Path)
	params, err := json.Marshal(map[string]any{
		"context": workspace.ContextRef, "resource": map[string]string{"rootID": root, "path": "src"},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := pluginhost.WithCaller(context.Background(), caller)
	result, refusal := service.HostServices.Respond(ctx, pluginhost.MethodPrefix+"workspace/watch", params)
	var subscription struct {
		ID string `json:"subscriptionID"`
	}
	if err := json.Unmarshal(result, &subscription); refusal != nil || err != nil || subscription.ID == "" {
		t.Fatalf("watch = %s, %+v, %v", result, refusal, err)
	}
	wait, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	await := func(sequence uint64, rescan bool, paths ...string) {
		t.Helper()
		select {
		case note := <-kernel.events:
			var message struct {
				ID       string `json:"subscriptionID"`
				Sequence uint64
				Event    struct {
					RootID         string
					ChangedPaths   []string
					RequiresRescan bool
				}
			}
			if err := json.Unmarshal(note.body, &message); err != nil {
				t.Fatal(err)
			}
			if note.session != session || note.method != notifySubscription || message.ID != subscription.ID ||
				message.Sequence != sequence || message.Event.RootID != root ||
				message.Event.RequiresRescan != rescan || !slices.Equal(message.Event.ChangedPaths, paths) {
				t.Fatalf("notification %s %s %s", note.session, note.method, note.body)
			}
		case <-wait.Done():
			t.Fatalf("waiting for watch event %d: %v", sequence, wait.Err())
		}
	}
	foreign := pluginhost.Caller{PluginID: plugin, SessionID: "other-session"}
	service.resources.dispose(foreign, subscription.ID)
	old := binding.CaptureConnection()
	service.PublishRemoteWorkspaceChanges(binding, old, []string{"/home/dev/work/src/one"}, false)
	await(1, false, "src/one")

	binding.Attach("replacement")
	service.PublishRemoteWorkspaceChanges(binding, old, []string{"/home/dev/work/src/from-old"}, false)
	await(2, true)

	current := binding.CaptureConnection()
	service.PublishRemoteWorkspaceChanges(binding, current, []string{"/home/dev/work/src/two"}, false)
	await(3, false, "src/two")
	service.PublishRemoteWorkspaceChanges(binding, current, make([]string, maxWorkspaceWatchPaths+1), false)
	await(4, true)

	service.resources.dispose(caller, subscription.ID)
	service.workspaceWatchesMu.Lock()
	defer service.workspaceWatchesMu.Unlock()
	if len(service.workspaceWatches) != 0 {
		t.Fatal("disposing the subscription left its watch registered")
	}
}
