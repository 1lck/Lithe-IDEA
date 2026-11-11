package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func readExecutionFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "execution", name))
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

// TestInspectAndGenerateRunConfigurationsNeverWriteTheWorkspace detects the
// entries of a small Node project and shows the folder holds nothing new.
func TestInspectAndGenerateRunConfigurationsNeverWriteTheWorkspace(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "package.json"), []byte(`{"name":"demo","scripts":{"start":"node index.js"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	client := NewClient()
	before, err := client.InspectRunConfigurations(ctx, root, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if before.Status != "missing" || !before.RequiresGeneration {
		t.Fatalf("before detection: %+v", before)
	}
	generation, err := client.GenerateRunConfigurations(ctx, root, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if generation.EntryCount != len(generation.Generated.Configurations) {
		t.Fatalf("entry count %d does not match %d entries", generation.EntryCount, len(generation.Generated.Configurations))
	}
	after, err := client.InspectRunConfigurations(ctx, root, nil, nil)
	if err != nil || after.Status != "ready" || after.Generated == nil {
		t.Fatalf("after detection: %+v, %v", after, err)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 1 {
		t.Fatalf("the workspace gained files: %v %v", entries, err)
	}
}
