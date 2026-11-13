package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A provider run snapshot becomes one effective build.provider configuration whose
// reference names the run, and its launch inputs carry the saved local choices.
func TestProviderRunsResolveAndLaunchInputs(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app"), 0o755); err != nil {
		t.Fatal(err)
	}
	reference := RunProviderReference{PluginID: "dev.example.engine", BuildSystemID: "engine", Root: "app", Run: "application",
		ProjectID: "app", TargetID: "main", UserArguments: []string{}}
	runs, err := json.Marshal([]RunProviderRun{{ProjectPath: "app", Name: "Run Main", Reference: reference}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GenerateRunConfigurations(ctx, root, "", runs); err != nil {
		t.Fatal(err)
	}
	resolved, err := client.ResolveRunConfigurations(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	if len(resolved.Configurations) != 1 {
		t.Fatalf("configurations = %+v", resolved.Configurations)
	}
	configuration := resolved.Configurations[0]
	got, ok := configuration.BuildReference()
	if !ok || got.TargetID != "main" || got.Run != "application" || configuration.Name != "Run Main" {
		t.Fatalf("configuration = %+v reference = %+v", configuration, got)
	}
	if resolved.DefaultRunConfiguration == nil || *resolved.DefaultRunConfiguration != configuration.ID {
		t.Fatalf("default = %v, want %s", resolved.DefaultRunConfiguration, configuration.ID)
	}
	inputs, err := client.ProviderLaunchInputs(ctx, root, configuration.ID, "app")
	if err != nil {
		t.Fatal(err)
	}
	if inputs.Reference.TargetID != "main" || inputs.LaunchOptions.Execution != "application" || inputs.LaunchOptions.Customized() {
		t.Fatalf("launch inputs = %+v", inputs)
	}
}

// An edit saved through updateOptions resolves back as the configuration's
// arguments, environment and working directory, and argumentText round-trips them.
func TestRunConfigurationOptionsRoundTrip(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app", "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	reference := RunProviderReference{PluginID: "dev.example.engine", BuildSystemID: "engine", Root: "app", Run: "application",
		ProjectID: "app", TargetID: "main", UserArguments: []string{}}
	runs, err := json.Marshal([]RunProviderRun{{ProjectPath: "app", Name: "Run Main", Reference: reference}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GenerateRunConfigurations(ctx, root, "", runs); err != nil {
		t.Fatal(err)
	}
	resolved, err := client.ResolveRunConfigurations(ctx, root)
	if err != nil || len(resolved.Configurations) != 1 {
		t.Fatalf("resolve = %+v, %v", resolved, err)
	}
	id := resolved.Configurations[0].ID
	document, err := client.UpdateRunConfigurationOptions(ctx, RunOptionsEdit{Root: root, Scope: "local", ConfigurationID: id,
		WorkingDirectory: "app/data", Arguments: `--name "Alice Smith"`, Environment: map[string]string{"MODE": "dev"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".lithe", "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".lithe", "run", "local.json"), []byte(document), 0o600); err != nil {
		t.Fatal(err)
	}
	resolved, err = client.ResolveRunConfigurations(ctx, root)
	if err != nil || len(resolved.Configurations) != 1 {
		t.Fatalf("resolve = %+v, %v", resolved, err)
	}
	got := resolved.Configurations[0]
	if len(got.Args) != 2 || got.Args[1] != "Alice Smith" || got.Env["MODE"] != "dev" || got.Cwd != "app/data" {
		t.Fatalf("configuration = %+v", got)
	}
	texts, err := client.RunArgumentText(ctx, [][]string{got.Args, {}})
	if err != nil || len(texts) != 2 || texts[0] != `--name "Alice Smith"` || texts[1] != "" {
		t.Fatalf("argument text = %q, %v", texts, err)
	}
}

// TestTitleActionsFollowTheContractFixture replays every title bar case through the typed
// wrapper.
func TestTitleActionsFollowTheContractFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "run-configuration", "title-action-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string           `json:"name"`
			Request  TitleActionFacts `json:"request"`
			Expected struct {
				Kind string `json:"kind"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, testCase := range fixture.Cases {
		got, err := client.DecideTitleAction(ctx, testCase.Request)
		if err != nil {
			t.Fatalf("%s: %v", testCase.Name, err)
		}
		if got != testCase.Expected.Kind {
			t.Fatalf("%s: decision = %q, want %q", testCase.Name, got, testCase.Expected.Kind)
		}
	}
}
