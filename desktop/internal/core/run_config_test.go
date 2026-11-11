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
