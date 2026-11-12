package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

var errSettingsPlanCaptured = errors.New("test stopped after capturing the language-server plan")

type settingsPlanningKernel struct {
	*fakeKernel
	client               *core.Client
	directories          core.PluginBackendDirectories
	planned              int
	updatedSession       string
	updatedConfiguration json.RawMessage
}

func (k *settingsPlanningKernel) PlanPluginLanguageServer(_ context.Context, _ json.RawMessage, _ string, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	k.directories = directories
	k.planned++
	return core.PluginBackendPlan{}, errSettingsPlanCaptured
}

func (k *settingsPlanningKernel) ReadPluginSettingsState(ctx context.Context, manifest json.RawMessage, global, project *string) (core.PluginSettingsState, error) {
	return k.client.ReadPluginSettingsState(ctx, manifest, global, project)
}

func (k *settingsPlanningKernel) EditPluginSettings(ctx context.Context, manifest json.RawMessage, scope string, document *string, edits []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error) {
	return k.client.EditPluginSettings(ctx, manifest, scope, document, edits)
}

func TestLanguageServerReadsActualPluginPreferenceLayersBeforePlanning(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		name := "project-overrides-global"
		if malformed {
			name = "malformed-source-does-not-plan-a-process"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
			if err != nil {
				t.Fatal(err)
			}
			var fixture struct {
				Manifest json.RawMessage `json:"manifest"`
			}
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatal(err)
			}
			preferences, plugins, workspace := t.TempDir(), t.TempDir(), t.TempDir()
			packageRoot := filepath.Join(plugins, "dev.example.settings", "1.0.0")
			if err := os.MkdirAll(packageRoot, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(packageRoot, pluginpkg.ManifestFile), fixture.Manifest, 0o600); err != nil {
				t.Fatal(err)
			}
			global := []byte(`{"dev.example.settings":{"flag":false}}`)
			if malformed {
				global = []byte("malformed preferences")
			}
			if err := os.WriteFile(filepath.Join(preferences, "plugin-settings.json"), global, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(filepath.Join(workspace, ".lithe"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(workspace, ".lithe", "plugin-settings.json"), []byte(`{"dev.example.settings":{"flag":true}}`), 0o600); err != nil {
				t.Fatal(err)
			}
			kernel := &settingsPlanningKernel{fakeKernel: &fakeKernel{}, client: core.NewClient()}
			service, err := Open(kernel, store.At(preferences), plugins)
			if err != nil {
				t.Fatal(err)
			}
			entry := pluginmanager.Entry{Enabled: true, Installed: pluginpkg.Installed{ID: "dev.example.settings", Version: "1.0.0", Path: packageRoot}}
			_, err = service.StartLanguageServer(ctx, []pluginmanager.Entry{entry}, "fixture", BackendRequest{WorkingDirectory: workspace, Architecture: core.PluginArchitecture()})
			if malformed {
				if err == nil || kernel.planned != 0 {
					t.Fatalf("malformed settings reached process planning: plans=%d, error=%v", kernel.planned, err)
				}
				return
			}
			if !errors.Is(err, errSettingsPlanCaptured) {
				t.Fatalf("plan boundary: %v", err)
			}
			if string(kernel.directories.Settings["flag"]) != "false" || string(kernel.directories.ProjectSettings["flag"]) != "true" {
				t.Fatalf("actual settings were ignored: global=%s project=%s", kernel.directories.Settings["flag"], kernel.directories.ProjectSettings["flag"])
			}
		})
	}
}

func (k *settingsPlanningKernel) ExpandPluginWorkspaceConfiguration(ctx context.Context, manifest json.RawMessage, languageID string, global, project map[string]json.RawMessage) (json.RawMessage, error) {
	return k.client.ExpandPluginWorkspaceConfiguration(ctx, manifest, languageID, global, project)
}

func (k *settingsPlanningKernel) UpdatePluginWorkspaceConfiguration(_ context.Context, session string, configuration json.RawMessage) (bool, error) {
	k.updatedSession = session
	k.updatedConfiguration = append(json.RawMessage(nil), configuration...)
	return true, nil
}

func TestSavedProjectSettingIsRereadBeforeUpdatingTheCurrentLanguageSession(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	kernel := &settingsPlanningKernel{fakeKernel: &fakeKernel{}, client: core.NewClient()}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()
	snapshot, err := service.Settings.Load(ctx, manifest, workspace)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := service.Settings.Save(ctx, snapshot, "project", []core.PluginSettingEdit{{ID: "dialyzer", Value: json.RawMessage(`false`)}}, nil)
	if err != nil || !saved.Committed || saved.Readback == nil {
		t.Fatalf("save actual source: %+v, %v", saved, err)
	}
	if len(saved.Effects) != 1 || saved.Effects[0] != "immediate" {
		t.Fatalf("unexpected Core effects: %v", saved.Effects)
	}
	session := &LanguageSession{PluginID: "dev.lithe.fixture.settings", Version: "0.1.0", LanguageID: "elixir", manifest: manifest, workspace: workspace, Session: pluginbackend.Session{ID: "current-language-session"}}
	result, err := service.ApplyLanguageSettings(ctx, session)
	if err != nil || !result.Available || !result.Sent {
		t.Fatalf("apply saved source: %+v, %v", result, err)
	}
	if kernel.updatedSession != session.Session.ID || string(kernel.updatedConfiguration) != `{"elixirLS":{"dialyzerEnabled":false}}` {
		t.Fatalf("wrong live source/session: %s %s", kernel.updatedSession, kernel.updatedConfiguration)
	}
	// A later unreadable source must keep the current server's configuration,
	// rather than push an empty/default replacement into its live session.
	kernel.updatedSession = ""
	if err := os.WriteFile(filepath.Join(workspace, ".lithe", "plugin-settings.json"), []byte("malformed source"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ApplyLanguageSettings(ctx, session); err == nil || kernel.updatedSession != "" {
		t.Fatalf("invalid source changed the live session: session=%q error=%v", kernel.updatedSession, err)
	}
}
