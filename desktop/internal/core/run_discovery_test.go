package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func readExecutionFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("execution/" + name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestResolveSearchPathFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				Existing        []string              `json:"existing"`
				Candidates      []SearchPathCandidate `json:"candidates"`
				CaseInsensitive bool                  `json:"caseInsensitive"`
			} `json:"request"`
			Expected []string `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readExecutionFixture(t, "search-path-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			got, err := NewClient().ResolveSearchPath(ctx, test.Request.Existing, test.Request.Candidates, test.Request.CaseInsensitive)
			if err != nil || !reflect.DeepEqual(got, test.Expected) {
				t.Fatalf("got %v, %v; want %v", got, err, test.Expected)
			}
		})
	}
}

func TestResolveExecutionEnvironmentFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Name     string                      `json:"name"`
			Request  ExecutionEnvironmentRequest `json:"request"`
			Expected struct {
				Environment map[string]string `json:"environment"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readExecutionFixture(t, "launch-environment-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			got, err := NewClient().ResolveExecutionEnvironment(ctx, test.Request)
			if err != nil || !reflect.DeepEqual(got, test.Expected.Environment) {
				t.Fatalf("got %v, %v; want %v", got, err, test.Expected.Environment)
			}
		})
	}
}

// TestGenerateRunConfigurationsNeverWritesTheWorkspace generates the run one
// provider declares and shows the folder holds nothing new.
func TestGenerateRunConfigurationsNeverWritesTheWorkspace(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app"), 0o755); err != nil {
		t.Fatal(err)
	}
	reference := RunProviderReference{PluginID: "dev.example.engine", BuildSystemID: "engine", Root: "app", Run: "application",
		ProjectID: "app", TargetID: "main", UserArguments: []string{}}
	runs, err := json.Marshal([]RunProviderRun{{ProjectPath: "app", Name: "Run Main", Reference: &reference}})
	if err != nil {
		t.Fatal(err)
	}
	generation, err := NewClient().GenerateRunConfigurations(debugContext(t), root, runs)
	if err != nil {
		t.Fatal(err)
	}
	if generation.EntryCount != 1 || len(generation.Generated.Configurations) != 1 {
		t.Fatalf("generated %d entries, %d configurations; want 1", generation.EntryCount, len(generation.Generated.Configurations))
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 1 || entries[0].Name() != "app" {
		t.Fatalf("the workspace gained files: %v %v", entries, err)
	}
}
