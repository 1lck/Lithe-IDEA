package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// launchConfigurationKernel plans, decodes and expands with the real Core and
// answers the launch function itself: the answer derives the server's
// configuration from the `strict` setting the function receives.
type launchConfigurationKernel struct {
	*fakeKernel
	client  *core.Client
	backend *BackendSession
	carries bool

	mu            sync.Mutex
	calls         int
	configuration json.RawMessage
}

func (k *launchConfigurationKernel) PlanPluginLanguageServer(ctx context.Context, manifest json.RawMessage, languageID string, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	return k.client.PlanPluginLanguageServer(ctx, manifest, languageID, directories)
}

func (k *launchConfigurationKernel) DecodePluginLanguageServerLaunch(ctx context.Context, manifest json.RawMessage, languageID string, directories core.PluginBackendDirectories, answer json.RawMessage) (core.PluginBackendPlan, error) {
	return k.client.DecodePluginLanguageServerLaunch(ctx, manifest, languageID, directories, answer)
}

func (k *launchConfigurationKernel) ReadPluginSettingsState(ctx context.Context, manifest json.RawMessage, global, project *string, localization *core.PluginSettingsLocalizationRequest) (core.PluginSettingsState, error) {
	return k.client.ReadPluginSettingsState(ctx, manifest, global, project, localization)
}

func (k *launchConfigurationKernel) EditPluginSettings(ctx context.Context, manifest json.RawMessage, scope string, document *string, edits []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error) {
	return k.client.EditPluginSettings(ctx, manifest, scope, document, edits)
}

func (k *launchConfigurationKernel) ExpandPluginWorkspaceConfiguration(ctx context.Context, manifest json.RawMessage, languageID string, global, project map[string]json.RawMessage) (json.RawMessage, error) {
	return k.client.ExpandPluginWorkspaceConfiguration(ctx, manifest, languageID, global, project)
}

func (k *launchConfigurationKernel) UpdatePluginWorkspaceConfiguration(_ context.Context, _ string, configuration json.RawMessage) (bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.configuration = append(json.RawMessage(nil), configuration...)
	return true, nil
}

func (k *launchConfigurationKernel) InvokePluginFunctionInContext(_ context.Context, _, operation, _, function string, params, _ json.RawMessage, _ int) (string, error) {
	var request struct {
		Settings struct {
			Strict bool `json:"strict"`
		} `json:"settings"`
	}
	if err := json.Unmarshal(params, &request); err != nil {
		return "", err
	}
	k.mu.Lock()
	k.calls++
	k.mu.Unlock()
	checks := "relaxed"
	if request.Settings.Strict {
		checks = "strict"
	}
	answer := map[string]any{"executable": map[string]string{"kind": "packaged", "path": "server/bin/metals"}}
	if k.carries {
		answer["workspaceConfiguration"] = map[string]any{"metals": map[string]string{"checks": checks}}
	}
	value, err := json.Marshal(map[string]any{"value": answer})
	if err != nil {
		return "", err
	}
	go k.backend.observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: value})
	return operation, nil
}

func (k *launchConfigurationKernel) counts() (int, string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.calls, string(k.configuration)
}

// backendLaunchSettingsManifest is the contract's backend-launched server with
// an immediate project setting and a declarative template for it.
func backendLaunchSettingsManifest(t *testing.T) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(contractfixture.Path("fixtures/languages/language-server-backend-launch.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["settings"] = 0
	manifest["settings"] = []any{map[string]any{
		"id": "strict", "type": "boolean", "title": "Strict", "default": false,
		"scope": "project", "effect": "immediate", "page": map[string]any{"languageID": "scala"},
	}}
	server := manifest["languageServers"].([]any)[0].(map[string]any)
	server["workspaceConfiguration"] = map[string]any{"metals": map[string]any{"strict": "${setting:strict}"}}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestImmediateSettingAsksTheBackendForTheConfigurationItsLaunchAnswered(t *testing.T) {
	for _, carries := range []bool{true, false} {
		name := "answer-carries-configuration"
		if !carries {
			name = "answer-leaves-the-declaration"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			manifest := backendLaunchSettingsManifest(t)
			kernel := &launchConfigurationKernel{fakeKernel: &fakeKernel{}, client: core.NewClient(), carries: carries}
			service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			const pluginID = "dev.lithe.fixture.language-server-backend-launch"
			backend := &BackendSession{
				host: service.Host, PluginID: pluginID, Version: "0.1.0",
				Session:   pluginbackend.Session{ID: "backend-1"},
				functions: map[string]bool{"metals.resolveLaunch": true}, waiters: map[string]chan core.BackendEvent{},
				done: make(chan struct{}), changed: make(chan struct{}), ready: true,
			}
			kernel.backend = backend
			service.Host.sessions[pluginID] = backend

			workspace := t.TempDir()
			workspaceContext := service.Contexts.Open(workspace)
			t.Cleanup(service.Contexts.CloseAll)
			snapshot, err := service.Settings.Load(ctx, manifest, workspace)
			if err != nil {
				t.Fatal(err)
			}
			start := pluginbackend.StartRequest{
				PackageDirectory:   t.TempDir(),
				StateDirectory:     t.TempDir(),
				LogDirectory:       t.TempDir(),
				Architecture:       core.PluginArchitecture(),
				Settings:           snapshot.State.Settings,
				ProjectSettings:    snapshot.State.ProjectSettings,
				ProjectCodeAllowed: true,
			}
			resolved, err := service.resolveBackendLaunch(ctx, pluginID, "0.1.0", manifest, "scala", workspaceContext, start, RuntimeEnvironment{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { removeTemporary(resolved.directories.temporary) })
			if (resolved.configuration != nil) != carries {
				t.Fatalf("kept the launch for later answers = %v, the answer carried a configuration = %v", resolved.configuration != nil, carries)
			}

			saved, err := service.Settings.Save(ctx, snapshot, "project", []core.PluginSettingEdit{{ID: "strict", Value: json.RawMessage(`true`)}}, nil)
			if err != nil || !saved.Committed {
				t.Fatalf("save the setting: %+v, %v", saved, err)
			}
			session := &LanguageSession{
				PluginID: pluginID, Version: "0.1.0", LanguageID: "scala", manifest: manifest, workspace: workspace,
				Session: pluginbackend.Session{ID: "language-1"}, launch: resolved.configuration,
			}
			result, err := service.ApplyLanguageSettings(ctx, session)
			if err != nil || !result.Available || !result.Sent {
				t.Fatalf("apply the setting: %+v, %v", result, err)
			}
			calls, configuration := kernel.counts()
			if carries {
				// The backend derives its configuration from the settings, so the
				// declaration's expansion would replace what it answered.
				if calls != 2 || configuration != `{"metals":{"checks":"strict"}}` {
					t.Fatalf("calls = %d, configuration = %s", calls, configuration)
				}
				return
			}
			// Without one, the declaration is the configuration, and the launch
			// function, which may install or download, is not asked again.
			if calls != 1 || configuration != `{"metals":{"strict":true}}` {
				t.Fatalf("calls = %d, configuration = %s", calls, configuration)
			}
		})
	}
}
