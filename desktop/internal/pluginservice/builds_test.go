package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

func TestBuildProviderManifestNeedsTheBuildCapabilities(t *testing.T) {
	// The fixture plugins also require settings; this minimal declaration keeps
	// the test about the build gate itself, not about the settings surface that
	// this client does not advertise yet.
	manifest := json.RawMessage(`{
		"schemaVersion": 0,
		"id": "dev.lithe.fixture.build-gate",
		"displayName": "Build Gate",
		"version": "1.0.0",
		"pluginAPIVersion": 0,
		"requires": {"buildProviders": 0, "buildSystems": 0},
		"vendor": {"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions": ["languageServer.launch", "process.build"],
		"activationEvents": ["onBuildSystem:fixture"],
		"languages": [],
		"buildSystems": [{
			"id": "fixture",
			"displayName": "Fixture",
			"detection": {"markers": ["fixture.marker"], "nesting": "outermost"},
			"invocation": {"executables": [{"kind": "command", "command": "fixture-tool"}]},
			"provider": {
				"launch": {"kind": "packaged", "path": "provider"},
				"arguments": [],
				"executesProjectCode": false,
				"mayUseNetwork": false
			},
			"model": {"source": "provider"},
			"tasks": [{
				"id": "build",
				"displayName": "Build",
				"group": "build",
				"scopes": ["workspace"],
				"source": "provider",
				"arguments": []
			}]
		}]
	}`)
	client, ctx := core.NewClient(), context.Background()
	_, err := client.ValidatePluginManifest(ctx, manifest, map[string][]int{
		"languages": {0}, "languageServers": {0},
	})
	var rejection *core.MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.api.unsupported" {
		t.Fatalf("a build provider installed without its capabilities: %v", err)
	}
	if rejection.Field != "requires.buildProviders" && rejection.Field != "requires.buildSystems" {
		t.Fatalf("the refusal named %q, want a build capability", rejection.Field)
	}
	if _, err := client.ValidatePluginManifest(ctx, manifest, pluginhost.Declared().Clone()); err != nil {
		t.Fatalf("the declared build capabilities did not admit the provider: %v", err)
	}
}

func TestBuildPluginsReadsProviderTasksAndRuns(t *testing.T) {
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/build-providers/build-provider-run-preparation.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	directory := filepath.Join(root, "dev.lithe.fixture.run", "1.0.0")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	service := &Service{kernel: &fakeKernel{}}
	plugins, err := service.BuildPlugins(context.Background(), []pluginmanager.Entry{{
		Installed: pluginpkg.Installed{ID: "dev.lithe.fixture.run", Version: "1.0.0", Path: directory},
		Enabled:   true,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(plugins) != 1 {
		t.Fatalf("plugins = %+v", plugins)
	}
	system := plugins[0].Systems["gradle"]
	if !system.Provider {
		t.Fatal("the provider flag was lost")
	}
	if len(system.Tasks) == 0 || system.Tasks[0].Source != "provider" {
		t.Fatalf("tasks = %+v", system.Tasks)
	}
	if len(system.Runs) != 1 || system.Runs[0].ID != "application" || len(system.Runs[0].Tags) != 1 || system.Runs[0].Tags[0] != "application" {
		t.Fatalf("runs = %+v", system.Runs)
	}
}

func TestBuildPluginsSkipsDisabledPlugins(t *testing.T) {
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/build-providers/build-provider-execution.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	directory := filepath.Join(root, "disabled", "1.0.0")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	service := &Service{kernel: &fakeKernel{}}
	plugins, err := service.BuildPlugins(context.Background(), []pluginmanager.Entry{{
		Installed: pluginpkg.Installed{ID: "disabled", Version: "1.0.0", Path: directory},
		Enabled:   false,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(plugins) != 0 {
		t.Fatalf("plugins = %+v", plugins)
	}
}

// Ensure the manifest stays valid JSON if a future fixture carries a comment.
var _ = json.Valid
