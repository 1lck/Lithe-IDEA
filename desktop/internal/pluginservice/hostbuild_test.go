package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type buildWatchNotification struct {
	session, method string
	body            json.RawMessage
}

type buildWatchKernel struct {
	fakeKernel
	events chan buildWatchNotification
}

func (k *buildWatchKernel) SendPluginHostNotification(ctx context.Context, session, method string, params json.RawMessage) (bool, error) {
	select {
	case k.events <- buildWatchNotification{session, method, params}:
		return true, nil
	case <-ctx.Done():
		return false, ctx.Err()
	}
}

func TestBuildConfigurationWatchFollowsCreatedDirectoryAndAtomicSaves(t *testing.T) {
	kernel := &buildWatchKernel{events: make(chan buildWatchNotification, 8)}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	workspace := service.Contexts.Open(root)
	t.Cleanup(func() { service.Contexts.Close(root) })
	const pluginID = "dev.lithe.test.build-options"
	session := runningActionSession(service, pluginID, "session-build-options")
	home := filepath.Join(t.TempDir(), "new-home")
	file := filepath.Join(home, "build.properties")
	request, err := json.Marshal(map[string]any{"context": workspace.ContextRef, "files": []string{file}})
	if err != nil {
		t.Fatal(err)
	}
	ctx := pluginhost.WithCaller(context.Background(), pluginhost.Caller{PluginID: pluginID, SessionID: session.Session.ID})
	result, refusal := service.HostServices.Respond(ctx, methodBuildWatchConfiguration, request)
	var subscription struct {
		ID string `json:"subscriptionID"`
	}
	if err := json.Unmarshal(result, &subscription); refusal != nil || err != nil || subscription.ID == "" {
		t.Fatalf("watch result = %s, refusal = %+v, error = %v", result, refusal, err)
	}
	var sequence uint64
	await := func(operation string) {
		t.Helper()
		timer := time.NewTimer(3 * time.Second)
		defer timer.Stop()
		select {
		case notification := <-kernel.events:
			var value struct {
				ID       string            `json:"subscriptionID"`
				Sequence uint64            `json:"sequence"`
				Event    map[string]string `json:"event"`
			}
			err := json.Unmarshal(notification.body, &value)
			if err != nil || notification.session != session.Session.ID || notification.method != notifySubscription ||
				value.ID != subscription.ID || value.Sequence <= sequence || len(value.Event) != 1 || value.Event["type"] != "changed" {
				t.Fatalf("%s notification = %+v, payload = %s, error = %v", operation, notification, notification.body, err)
			}
			sequence = value.Sequence
		case <-timer.C:
			t.Fatalf("%s did not invalidate the configuration", operation)
		}
	}
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	await("directory creation")
	staging := filepath.Join(home, "next")
	if err := os.WriteFile(staging, []byte("build.memory=512m\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(staging, file); err != nil {
		t.Fatal(err)
	}
	await("atomic save")
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	await("file removal")
	service.Contexts.Close(root)
	service.resources.mu.Lock()
	remaining := len(service.resources.byID)
	service.resources.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("closed workspace still has %d resources", remaining)
	}
}
