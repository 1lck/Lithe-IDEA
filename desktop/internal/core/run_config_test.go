package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
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
	if _, err := client.GenerateRunConfigurations(ctx, root, runs); err != nil {
		t.Fatal(err)
	}
	resolved, err := client.ResolveRunConfigurations(ctx, root, nil)
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
	if _, err := client.GenerateRunConfigurations(ctx, root, runs); err != nil {
		t.Fatal(err)
	}
	resolved, err := client.ResolveRunConfigurations(ctx, root, nil)
	if err != nil || len(resolved.Configurations) != 1 {
		t.Fatalf("resolve = %+v, %v", resolved, err)
	}
	id := resolved.Configurations[0].ID
	changes, err := client.UpdateRunConfigurationOptions(ctx, RunOptionsEdit{Root: root, Scope: "local", ConfigurationID: id,
		WorkingDirectory: "app/data", Arguments: `--name "Alice Smith"`, Environment: map[string]string{"MODE": "dev"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 || changes[0].Path != ".lithe/run/plugin/dev.example.engine.local.toml" || changes[0].BaseSHA256 != nil {
		t.Fatalf("changes = %+v", changes)
	}
	writeRunConfigChanges(t, root, changes)
	resolved, err = client.ResolveRunConfigurations(ctx, root, nil)
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
	data, err := os.ReadFile(contractfixture.CoreFixture("run-configuration/title-action-v1.json"))
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

// writeRunConfigChanges applies the file changes of an edit command as the host would, without
// its base checks: a test owns the workspace.
func writeRunConfigChanges(t *testing.T, root string, changes []RunConfigChange) {
	t.Helper()
	for _, change := range changes {
		path := filepath.Join(root, filepath.FromSlash(change.Path))
		if change.Content == nil {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(*change.Content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// A shell script saved as text goes through the built-in process API: the kinds list it, the
// editor describes its fields, saving refuses a missing value and then writes the project
// layer, the configuration resolves without any plugin, its plan carries the script for the
// host to write, and deleting removes it again.
func TestBuiltInProcessRunRoundTrip(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := t.TempDir()
	kinds, _, err := client.RunConfigurationTypes(ctx, nil)
	if err != nil || len(kinds) == 0 || kinds[0].Provider != "process.shell" {
		t.Fatalf("kinds = %+v, %v", kinds, err)
	}
	form, err := client.RunEditorForm(ctx, RunEditorFormRequest{Root: root, Provider: "process.shell"})
	if err != nil || form.FormVersion != RunFormVersion || form.ConfigurationID != nil || len(form.Fields) == 0 || form.Fields[0].ID != "name" {
		t.Fatalf("form = %+v, %v", form, err)
	}
	values := form.Values
	values["source"] = json.RawMessage(`"text"`)
	values["name"] = json.RawMessage(`"Greet"`)
	values["storeAsProjectFile"] = json.RawMessage(`true`)
	invalid, err := client.SaveRunConfiguration(ctx, RunConfigurationSave{Root: root, Provider: "process.shell", Values: values})
	if err != nil || invalid.Status != "invalid" || len(invalid.Errors) != 1 || invalid.Errors[0] != (RunFieldError{Field: "text", Code: "required"}) {
		t.Fatalf("save without text = %+v, %v", invalid, err)
	}
	values["text"] = json.RawMessage(`"echo hello"`)
	saved, err := client.SaveRunConfiguration(ctx, RunConfigurationSave{Root: root, Provider: "process.shell", Values: values})
	if err != nil || saved.Status != "saved" || !strings.HasPrefix(saved.ID, "user:") || len(saved.Changes) != 1 || saved.Changes[0].Path != ".lithe/run/configurations.yaml" {
		t.Fatalf("save = %+v, %v", saved, err)
	}
	writeRunConfigChanges(t, root, saved.Changes)
	resolved, err := client.ResolveRunConfigurations(ctx, root, nil)
	if err != nil || len(resolved.Configurations) != 1 {
		t.Fatalf("resolve = %+v, %v", resolved, err)
	}
	if got := resolved.Configurations[0]; got.ID != saved.ID || got.Name != "Greet" || !got.IsProcess() || got.Unavailable() || !got.UserDefined() {
		t.Fatalf("configuration = %+v", got)
	}
	base := filepath.Join(t.TempDir(), "script")
	plan, err := client.CreateRunLaunchPlan(ctx, root, saved.ID, base)
	if err != nil || plan.InlineScript == nil || plan.InlineScript.Content != "echo hello\n" || !strings.HasPrefix(plan.InlineScript.Path, base) || plan.WorkingDirectory != "." {
		t.Fatalf("plan = %+v, %v", plan, err)
	}
	if plan.Executable.Command == "" && plan.Executable.Path == "" || !slices.Contains(plan.Arguments, plan.InlineScript.Path) {
		t.Fatalf("plan does not run the script with the shell: %+v", plan)
	}
	removed, err := client.DeleteRunConfiguration(ctx, root, saved.ID, nil)
	if err != nil || len(removed) != 1 || removed[0].Path != ".lithe/run/configurations.yaml" || removed[0].BaseSHA256 == nil {
		t.Fatalf("delete = %+v, %v", removed, err)
	}
	writeRunConfigChanges(t, root, removed)
	if resolved, err := client.ResolveRunConfigurations(ctx, root, nil); err != nil || len(resolved.Configurations) != 0 {
		t.Fatalf("resolve after delete = %+v, %v", resolved, err)
	}
}
