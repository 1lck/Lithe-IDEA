package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
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
			const (
				created  = "create/note.txt"
				replaced = "replace/note.txt"
				staging  = "replace/next.txt"
				removed  = "remove/note.txt"
				burst    = "burst/note.txt"
				next     = "burst/next.txt"
			)
			// Each operation owns its own directory. A native batch can
			// report just the parent, and later batches can repeat its name.
			// Prepare existing entries before the subscription starts.
			for _, path := range []string{created, replaced, removed, burst} {
				if err := os.Mkdir(filepath.Join(root, filepath.Dir(path)), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			for _, path := range []string{replaced, staging, removed, burst, next} {
				if err := os.WriteFile(filepath.Join(root, path), []byte(path), 0o600); err != nil {
					t.Fatal(err)
				}
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
				parent := filepath.ToSlash(filepath.Dir(path))
				var observed [][]string
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
						if value.Event.RequiresRescan {
							return
						}
						if path != "" && (slices.Contains(value.Event.ChangedPaths, path) || slices.Contains(value.Event.ChangedPaths, parent)) {
							return
						}
						if len(observed) < cap(kernel.events) {
							observed = append(observed, value.Event.ChangedPaths)
						}
					case <-ctx.Done():
						t.Fatalf("%s did not reach the native watch for %q at sequence %d: %v (other batches: %v)", operation, path, sequence, ctx.Err(), observed)
					}
				}
			}
			await("initial rescan", "")
			if sequence != 1 {
				t.Fatalf("initial sequence = %d, want 1", sequence)
			}
			// Disposal is scoped to the plugin and exact backend session.
			service.resources.dispose(pluginhost.Caller{PluginID: plugin, SessionID: "replacement-session"}, id)
			if err := os.WriteFile(filepath.Join(root, created), []byte("first"), 0o600); err != nil {
				t.Fatal(err)
			}
			await("nested creation", created)
			if err := os.Rename(filepath.Join(root, staging), filepath.Join(root, replaced)); err != nil {
				t.Fatal(err)
			}
			await("atomic replacement", replaced)
			if err := os.Remove(filepath.Join(root, removed)); err != nil {
				t.Fatal(err)
			}
			await("deletion", removed)
			// A replace-and-remove burst can coalesce to a single change.
			if err := os.Rename(filepath.Join(root, next), filepath.Join(root, burst)); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(filepath.Join(root, burst)); err != nil {
				t.Fatal(err)
			}
			await("replacement and deletion burst", burst)
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
				if runtime.GOOS == "windows" {
					// ReadDirectoryChangesW keeps an open directory handle that blocks root replacement
					// across parents or misses self-rename resync on Windows (1lck/Lithe-IDEA#2374).
					t.Skip("ReadDirectoryChangesW keeps an open directory handle that blocks root replacement or misses self-rename resync on Windows (#2374)")
				}
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
