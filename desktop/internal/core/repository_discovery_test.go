package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestWorkspaceRepositoryDiscoveryUsesCoreRules(t *testing.T) {
	requireGit(t)
	root := plainDirectory(t)
	for _, name := range []string{"service-b", "service-a", ".cache/hidden"} {
		directory := filepath.Join(root, name)
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
		runGit(t, directory, "init", "-q")
	}
	// A stale .git marker is not a usable repository and must not poison the list.
	writeFile(t, filepath.Join(root, "stale", ".git"), "gitdir: absent\n")
	repositories, err := NewClient().DiscoverWorkspaceRepositories(testContext(t), root)
	if err != nil {
		t.Fatal(err)
	}
	want := []WorkspaceRepository{
		{Path: filepath.ToSlash(filepath.Join(root, "service-a"))},
		{Path: filepath.ToSlash(filepath.Join(root, "service-b"))},
	}
	if !reflect.DeepEqual(repositories, want) {
		t.Fatalf("repositories = %#v, want %#v", repositories, want)
	}
	nested := filepath.Join(root, "service-a", "nested")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	repositories, err = NewClient().DiscoverWorkspaceRepositories(testContext(t), nested)
	if err != nil || !reflect.DeepEqual(repositories, want[:1]) {
		t.Fatalf("nested workspace repositories = %#v, error = %v; want %#v", repositories, err, want[:1])
	}
}

func TestRepositoryColorAssignmentsUseCoreFixtures(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "git", "repository-colors-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string                 `json:"name"`
			Request  RepositoryColorRequest `json:"request"`
			Expected RepositoryColors       `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			result, err := client.AssignRepositoryColors(testContext(t), item.Request)
			if err != nil || !reflect.DeepEqual(result, item.Expected) {
				t.Fatalf("assignments = %#v, error = %v; want %#v", result, err, item.Expected)
			}
		})
	}
	_, err = client.AssignRepositoryColors(testContext(t), RepositoryColorRequest{TotalCount: 2, RepositoryIDs: []string{"same", "same"}})
	requireCode(t, err, CodeInvalidRequest)
}
