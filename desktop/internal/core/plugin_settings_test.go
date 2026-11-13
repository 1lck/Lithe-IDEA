package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestPluginSettingsDocumentSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
		Cases    []struct {
			Name      string              `json:"name"`
			Scope     string              `json:"scope"`
			Document  *string             `json:"document"`
			Edits     []PluginSettingEdit `json:"edits"`
			Expected  any                 `json:"expected"`
			ErrorCode string              `json:"errorCode"`
			Delete    bool                `json:"delete"`
			Unchanged bool                `json:"unchanged"`
			Effects   []string            `json:"effects"`
		} `json:"editCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			plan, err := client.EditPluginSettings(ctx, fixture.Manifest, test.Scope, test.Document, test.Edits)
			if test.ErrorCode != "" {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != test.ErrorCode {
					t.Fatalf("rejection = %v, want %s", err, test.ErrorCode)
				}
				if plan.Document != "" {
					t.Fatal("rejection exposed a partial replacement")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var document any
			if err := json.Unmarshal([]byte(plan.Document), &document); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(document, test.Expected) || plan.Delete != test.Delete || !reflect.DeepEqual(plan.Effects, test.Effects) {
				t.Fatalf("edit plan differs from shared fixture: %+v", plan)
			}
			if test.Unchanged && (plan.Changed || test.Document == nil || plan.Document != *test.Document) {
				t.Fatal("a semantic no-op rewrote the captured document")
			}
		})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	state, err := client.ReadPluginSettingsState(ctx, fixture.Manifest, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Rows) != 7 || state.Storage.MaximumBytes <= 0 || state.Storage.ProjectRelativePath == "" {
		t.Fatalf("state did not decode its rows and bounded read plan: %+v", state)
	}
	for _, row := range state.Rows {
		if row.Scope == "" || row.Effect == "" || row.Effective.Source != "default" || len(row.Effective.Value) == 0 {
			t.Fatalf("row lost Core's normalized fields: %+v", row)
		}
	}
}

func TestPluginWorkspaceConfigurationUpdatesTheSameRealSession(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	client := NewClient()
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	initial, err := client.ExpandPluginWorkspaceConfiguration(ctx, manifest, "elixir", map[string]json.RawMessage{"dialyzer": json.RawMessage(`false`)}, nil)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	uri, err := client.PluginDocumentURI(ctx, root, "auto")
	if err != nil {
		t.Fatal(err)
	}
	started, err := client.StartPluginLanguageServer(ctx, PluginBackendStart{ProviderID: "settings-configuration-peer", PluginID: "dev.lithe.fixture.settings", ExecutablePath: executable, Arguments: []string{"-test.run=^TestPluginBackendHelper$"}, Environment: map[string]string{"LITHE_TEST_PLUGIN_BACKEND": "1", "LITHE_TEST_PLUGIN_CONFIGURATION": "1"}, RootURI: uri, WorkingDirectory: root, WorkspaceConfiguration: initial, InitializeTimeoutMilliseconds: 3000, RequestTimeoutMilliseconds: 3000, ShutdownTimeoutMilliseconds: 2000})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		if err := stopTestPluginBackend(cleanup, client, started.SessionID); err != nil {
			t.Errorf("stop configuration peer: %v", err)
		}
	})
	awaitConfiguration := func(wanted string) {
		t.Helper()
		for ctx.Err() == nil {
			events, err := client.WaitBackendEvents(ctx, started.SessionID, 1000)
			if err != nil {
				t.Fatal(err)
			}
			for _, event := range events {
				var fields struct {
					Diagnostic string `json:"diagnostic"`
				}
				if len(event.Fields) > 0 {
					if err := json.Unmarshal(event.Fields, &fields); err != nil {
						t.Fatal(err)
					}
				}
				if fields.Diagnostic == "configuration:"+wanted {
					return
				}
				if event.Type == "exit" || (event.Type == "stateChanged" && event.State == "failed") {
					t.Fatalf("configuration peer ended before reply: %+v", event)
				}
			}
		}
		t.Fatalf("configuration reply %s: %v", wanted, ctx.Err())
	}
	awaitConfiguration(`[{"dialyzerEnabled":false}]`)
	updated, err := client.ExpandPluginWorkspaceConfiguration(ctx, manifest, "elixir", map[string]json.RawMessage{"dialyzer": json.RawMessage(`false`)}, map[string]json.RawMessage{"dialyzer": json.RawMessage(`true`)})
	if err != nil {
		t.Fatal(err)
	}
	sent, err := client.UpdatePluginWorkspaceConfiguration(ctx, started.SessionID, updated)
	if err != nil || !sent {
		t.Fatalf("live update: sent=%v, %v", sent, err)
	}
	awaitConfiguration(`[{"dialyzerEnabled":true}]`)
}

func TestInstalledPluginSettingsStateBindsRegistrationIdentityInCore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range []struct {
		id, version string
		reject      bool
	}{
		{"dev.example.settings", "1.0.0", false},
		{"dev.example.other", "1.0.0", true},
		{"dev.example.settings", "1.1.0", true},
	} {
		state, err := client.ReadInstalledPluginSettingsState(ctx, fixture.Manifest, test.id, test.version)
		if !test.reject {
			if err != nil || state.PluginID != test.id {
				t.Fatalf("matching owner rejected: %+v %v", state, err)
			}
			continue
		}
		var rejection *MarketplaceRejection
		if !errors.As(err, &rejection) || rejection.Code != "plugin.settings.ownerChanged" {
			t.Fatalf("mismatched owner accepted: %+v %v", state, err)
		}
	}
}
