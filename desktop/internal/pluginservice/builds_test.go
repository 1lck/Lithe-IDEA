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

// The Build window shows what a build system declares: command tasks with their categories and
// target tags, and the scopes its dependency request accepts. A system declaring only project
// dependencies (the Go modules plugin) must not be asked for those of the whole workspace,
// which Core refuses (plugin.build.invalidSelection).
func TestParseBuildSystemsKeepsTaskPresentationAndDependencyScopes(t *testing.T) {
	systems, err := parseBuildSystems(json.RawMessage(`{"buildSystems": [
		{
			"id": "go",
			"displayName": "Go Modules",
			"model": {"source": "command"},
			"dependencies": {"source": "command", "scopes": ["project"], "arguments": []},
			"tasks": [
				{"id": "build", "displayName": "Build", "group": "build", "scopes": ["project"], "arguments": []},
				{"id": "vet", "displayName": "Vet", "description": "Report suspicious code", "group": "verification",
				 "category": ["Checks", "Static"], "scopes": ["project", "target"], "targetTags": ["application"], "arguments": []}
			]
		},
		{"id": "plain"}
	]}`))
	if err != nil {
		t.Fatal(err)
	}
	goModules := systems["go"]
	if goModules.Provider {
		t.Fatal("a command model reads as a provider")
	}
	if goModules.Dependencies == nil || len(goModules.Dependencies.Scopes) != 1 || goModules.Dependencies.Scopes[0] != "project" {
		t.Fatalf("dependencies = %+v", goModules.Dependencies)
	}
	if len(goModules.Tasks) != 2 {
		t.Fatalf("tasks = %+v", goModules.Tasks)
	}
	if build := goModules.Tasks[0]; build.ID != "build" || build.Source != "" || build.Group != "build" || len(build.Category) != 0 {
		t.Fatalf("build task = %+v", build)
	}
	vet := goModules.Tasks[1]
	if vet.Description != "Report suspicious code" || len(vet.Category) != 2 || vet.Category[0] != "Checks" || vet.Category[1] != "Static" {
		t.Fatalf("vet presentation = %+v", vet)
	}
	if len(vet.Scopes) != 2 || vet.Scopes[1] != "target" || len(vet.TargetTags) != 1 || vet.TargetTags[0] != "application" {
		t.Fatalf("vet scopes = %+v", vet)
	}
	if systems["plain"].Dependencies != nil {
		t.Fatal("a system without dependencies offers them")
	}
}
