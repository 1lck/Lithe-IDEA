package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type buildOptionsKernel struct {
	fakeKernel
	client       *core.Client
	read         func(context.Context, string, int64) (*string, error)
	resolveError error
}

func (k *buildOptionsKernel) ReadWorkspaceConfiguration(ctx context.Context, path string, limit int64) (*string, error) {
	return k.read(ctx, path, limit)
}

func (k *buildOptionsKernel) ResolveStoredInstanceOptions(ctx context.Context, manifest json.RawMessage, systemID, root string, team, local json.RawMessage) (json.RawMessage, error) {
	result, err := k.client.ResolveStoredInstanceOptions(ctx, manifest, systemID, root, team, local)
	k.resolveError = err
	return result, err
}

func TestRemoteBuildOptionsReadTeamValuesAndClientOverrides(t *testing.T) {
	kernel := &buildOptionsKernel{client: core.NewClient()}
	prefs := store.At(t.TempDir())
	service, err := Open(kernel, prefs, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	placeholder := t.TempDir()
	binding := core.NewRemoteWorkspace(placeholder, "/home/dev/project", nil)
	binding.Attach("remote-build")
	workspace := service.Contexts.OpenRemote(binding, "project", "connection", core.RemotePlatform{OS: "linux", Arch: "x86_64"}, nil)
	t.Cleanup(service.Contexts.CloseAll)
	const pluginID = "dev.lithe.test.remote-build-options"
	session := runningActionSession(service, pluginID, "backend")
	session.manifest = json.RawMessage(`{
		"schemaVersion":0,"id":"dev.lithe.test.remote-build-options","displayName":"Test","version":"1.0.0","pluginAPIVersion":0,
		"requires":{"buildSystems":0},"vendor":{"id":"dev.lithe.test","displayName":"Test","signatureRequirement":"publisherPackage"},
		"permissions":["process.build"],"activationEvents":["onBuildSystem:fixture"],"languages":[],
		"buildSystems":[{
			"id":"fixture","displayName":"Fixture","detection":{"markers":["fixture.build"]},
			"invocation":{"executables":[{"kind":"command","command":"fixture-build"}]},
			"options":[{"id":"mode","displayName":"Mode","kind":"text","arguments":["--mode","${value}"]},{"id":"profile","displayName":"Profile","kind":"text","arguments":["--profile","${value}"]}],
			"model":{"source":"command","arguments":["model"],"decoder":"litheBuildModel","executesProjectCode":false,"mayUseNetwork":false},
			"tasks":[{"id":"compile","displayName":"Compile","group":"lifecycle","scopes":["workspace"],"arguments":["compile"]}]
		}]
	}`)
	team := `{"version":1,"systems":{"fixture":{"options":{"mode":"team","profile":"from host"}}}}`
	local := json.RawMessage(`{"version":1,"document":{"version":1,"systems":{"fixture":{"options":{"mode":"client"}}}}}`)
	if err := prefs.Save(buildprefs.LocalFile, map[string]json.RawMessage{placeholder: local}); err != nil {
		t.Fatal(err)
	}
	localTeam := filepath.Join(placeholder, buildprefs.TeamFile)
	if err := os.MkdirAll(filepath.Dir(localTeam), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(localTeam, []byte("invalid JSON in placeholder"), 0o600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	reconnect := false
	kernel.read = func(ctx context.Context, path string, limit int64) (*string, error) {
		calls++
		if core.RemoteWorkspaceOf(ctx) != binding || path != buildprefs.TeamFile || limit != 1<<20 {
			t.Fatalf("unexpected remote configuration read: %q, limit %d", path, limit)
		}
		if reconnect {
			binding.Attach("remote-build")
		}
		return &team, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ctx = pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: pluginID, SessionID: session.Session.ID})
	request := json.RawMessage(`{` + contextJSONOf(workspace) + `,"buildSystemID":"fixture","root":"."}`)
	result, refusal := service.HostServices.Respond(ctx, methodBuildGetOptions, request)
	var got struct{ Options map[string]string }
	if err := json.Unmarshal(result, &got); refusal != nil || err != nil || got.Options["mode"] != "client" || got.Options["profile"] != "from host" || calls != 1 {
		t.Fatalf("effective options = %s, refusal = %+v, decode error = %v, remote reads = %d, Core error = %+v", result, refusal, err, calls, kernel.resolveError)
	}
	reconnect = true
	if result, refusal := service.HostServices.Respond(ctx, methodBuildGetOptions, request); refusal == nil || refusal.Code != "plugin.host.remoteDisconnected" || result != nil {
		t.Fatalf("options from the replaced attachment = %s, %+v", result, refusal)
	}
	binding.Detach()
	if result, refusal := service.HostServices.Respond(ctx, methodBuildGetOptions, request); refusal == nil || refusal.Code != "plugin.host.remoteDisconnected" || result != nil || calls != 2 {
		t.Fatalf("options while disconnected = %s, %+v, remote reads = %d", result, refusal, calls)
	}
}

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
