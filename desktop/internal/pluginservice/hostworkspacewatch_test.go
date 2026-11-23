package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestWorkspaceWatchUsesNativeEventsAndReleasesOwnedSubscriptions(t *testing.T) {
	for _, ending := range []string{"dispose", "context", "session", "root-replacement"} {
		t.Run(ending, func(t *testing.T) {
			kernel := &buildWatchKernel{events: make(chan buildWatchNotification, 32)}
			service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if err := service.AttachWorkbench(diskReadWorkbench{&fakeWorkbench{}, core.NewClient()}); err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, "src"), 0o700); err != nil {
				t.Fatal(err)
			}
			workspace := service.Contexts.Open(root)
			t.Cleanup(func() { service.Contexts.Close(root) })
			const plugin = "dev.lithe.test.workspace-watch"
			session := runningActionSession(service, plugin, "workspace-watch-session")
			caller := pluginhost.Caller{PluginID: plugin, SessionID: session.Session.ID}
			ctx, cancel := context.WithTimeout(pluginhost.WithCaller(context.Background(), caller), 8*time.Second)
			defer cancel()
			rootID := service.Contexts.RootID(plugin, root)
			body, _ := json.Marshal(map[string]any{"context": workspace.ContextRef, "resource": Resource{rootID, ""}, "recursive": true})
			result, refusal := service.HostServices.Respond(ctx, methodWorkspaceWatch, body)
			var subscription struct{ SubscriptionID string }
			if err := json.Unmarshal(result, &subscription); err != nil || refusal != nil || subscription.SubscriptionID == "" {
				t.Fatalf("registration = %s, %+v, %v", result, refusal, err)
			}
			id := subscription.SubscriptionID
			defer service.resources.dispose(caller, id)
			released := make(chan struct{})
			service.resources.mu.Lock()
			release := service.resources.byID[id].dispose
			service.resources.byID[id].dispose = func() {
				release()
				close(released)
			}
			service.resources.mu.Unlock()
			var sequence uint64
			await := func(operation, path string) {
				t.Helper()
				for {
					select {
					case notification := <-kernel.events:
						var value struct {
							SubscriptionID string
							Sequence       uint64
							Event          struct {
								RootID         string
								ChangedPaths   []string
								RequiresRescan bool
							}
						}
						if err := json.Unmarshal(notification.body, &value); err != nil || notification.session != session.Session.ID || notification.method != notifySubscription || value.SubscriptionID != id || value.Sequence <= sequence || value.Event.RootID != rootID {
							t.Fatalf("%s notification = %+v, %v", operation, notification, err)
						}
						sequence = value.Sequence
						if path == "" && value.Event.RequiresRescan {
							return
						}
						if path != "" && (value.Event.RequiresRescan || slices.Contains(value.Event.ChangedPaths, path) || slices.Contains(value.Event.ChangedPaths, "src")) {
							return
						}
					case <-ctx.Done():
						t.Fatalf("%s did not reach the native watch: %v", operation, ctx.Err())
					}
				}
			}
			await("initial rescan", "")
			if sequence != 1 {
				t.Fatalf("initial sequence = %d, want 1", sequence)
			}
			// Disposal is scoped to the plugin and exact backend session.
			service.resources.dispose(pluginhost.Caller{PluginID: plugin, SessionID: "replacement-session"}, id)
			file := filepath.Join(root, "src", "a.txt")
			if err := os.WriteFile(file, []byte("first"), 0o600); err != nil {
				t.Fatal(err)
			}
			await("nested creation", "src/a.txt")
			staging := filepath.Join(root, "src", "next")
			if err := os.WriteFile(staging, []byte("saved"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Rename(staging, file); err != nil {
				t.Fatal(err)
			}
			await("atomic replacement", "src/a.txt")
			if err := os.Remove(file); err != nil {
				t.Fatal(err)
			}
			await("deletion", "src/a.txt")
			switch ending {
			case "dispose":
				params, _ := json.Marshal(map[string]string{"subscriptionID": id})
				if _, refusal := service.HostServices.Respond(ctx, pluginhost.MethodPrefix+"subscriptions/dispose", params); refusal != nil {
					t.Fatal(refusal)
				}
			case "context":
				service.Contexts.Close(root)
			case "session":
				service.resources.releaseSession(session.Session.ID)
			case "root-replacement":
				// Reusing the same path must not keep the old directory's stream alive.
				if err := os.Rename(root, filepath.Join(t.TempDir(), "old-root")); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(root, 0o700); err != nil {
					t.Fatal(err)
				}
				await("root replacement rescan", "")
			}
			select {
			case <-released:
			case <-ctx.Done():
				t.Fatalf("%s did not release its native stream: %v", ending, ctx.Err())
			}
			service.resources.mu.Lock()
			remaining := len(service.resources.byID)
			service.resources.mu.Unlock()
			if remaining != 0 {
				t.Fatalf("%s left %d native subscriptions", ending, remaining)
			}
		})
	}
}

type blockedWorkspaceNotification struct {
	fakeKernel
	started  chan struct{}
	finished chan struct{}
}

func (k *blockedWorkspaceNotification) SendPluginHostNotification(ctx context.Context, _, _ string, _ json.RawMessage) (bool, error) {
	close(k.started)
	defer close(k.finished)
	<-ctx.Done() // Production gives every notification a five-second deadline.
	return false, ctx.Err()
}

func TestWorkspaceWatchDisposeCancelsAnInFlightNotification(t *testing.T) {
	kernel := &blockedWorkspaceNotification{started: make(chan struct{}), finished: make(chan struct{})}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkbench(diskReadWorkbench{&fakeWorkbench{}, core.NewClient()}); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	workspace := service.Contexts.Open(root)
	defer service.Contexts.Close(root)
	const plugin = "dev.lithe.test.workspace-watch-cancel"
	session := runningActionSession(service, plugin, "workspace-watch-cancel-session")
	caller := pluginhost.Caller{PluginID: plugin, SessionID: session.Session.ID}
	ctx, cancel := context.WithTimeout(pluginhost.WithCaller(context.Background(), caller), 8*time.Second)
	defer cancel()
	body, _ := json.Marshal(map[string]any{"context": workspace.ContextRef, "resource": Resource{service.Contexts.RootID(plugin, root), ""}})
	// Check the shared per-session native limit before allocating an OS stream.
	var placeholders []string
	for range maxBuildConfigurationWatches {
		placeholders = append(placeholders, service.resources.addLimited(caller, workspace.ContextID, nil, maxBuildConfigurationWatches))
	}
	if _, refusal := service.HostServices.Respond(ctx, methodWorkspaceWatch, body); refusal == nil || refusal.Code != "plugin.host.limitExceeded" {
		t.Fatalf("limit = %+v", refusal)
	}
	for _, id := range placeholders {
		service.resources.dispose(caller, id)
	}
	result, refusal := service.HostServices.Respond(ctx, methodWorkspaceWatch, body)
	var subscription struct{ SubscriptionID string }
	if err := json.Unmarshal(result, &subscription); refusal != nil || err != nil || subscription.SubscriptionID == "" {
		t.Fatalf("registration = %s, %+v, %v", result, refusal, err)
	}
	id := subscription.SubscriptionID
	defer service.resources.dispose(caller, id)
	select {
	case <-kernel.started:
	case <-ctx.Done():
		t.Fatal("initial notification did not start")
	}
	service.resources.dispose(caller, id)
	// Disposal waits for the current delivery and closes the native registration.
	select {
	case <-kernel.finished:
	default:
		t.Fatal("dispose returned while a notification was still active")
	}
	service.resources.dispose(caller, id)
}
