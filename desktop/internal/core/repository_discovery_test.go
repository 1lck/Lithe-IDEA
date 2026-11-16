package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
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
	serviceA := filepath.ToSlash(filepath.Join(root, "service-a"))
	want := []WorkspaceRepository{
		{Path: serviceA, ID: "service-a", Name: "service-a", Role: RepositoryNested},
		{Path: filepath.ToSlash(filepath.Join(root, "service-b")), ID: "service-b", Name: "service-b", Role: RepositoryNested},
	}
	if !reflect.DeepEqual(repositories, want) {
		t.Fatalf("repositories = %#v, want %#v", repositories, want)
	}
	nested := filepath.Join(root, "service-a", "nested")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	repositories, err = NewClient().DiscoverWorkspaceRepositories(testContext(t), nested)
	containing := []WorkspaceRepository{{Path: serviceA, ID: "..", Name: "service-a", Role: RepositoryWorkspace}}
	if err != nil || !reflect.DeepEqual(repositories, containing) {
		t.Fatalf("nested workspace repositories = %#v, error = %v; want %#v", repositories, err, containing)
	}
}

// The bridge passes discovery entries through and decodes Core's answer; the rules are the
// fixtures' and Core's.
func TestWorkspaceRepositorySelectionUsesCoreFixtures(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("git/workspace-repository-selection-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				Repositories []WorkspaceRepository `json:"repositories"`
				Selected     string                `json:"selected"`
			} `json:"request"`
			Response struct {
				Active   *string  `json:"active"`
				FellBack bool     `json:"fellBack"`
				Others   []string `json:"others"`
			} `json:"response"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the selection fixture has no cases")
	}
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			want := WorkspaceRepositorySelection{FellBack: item.Response.FellBack, Others: item.Response.Others}
			if item.Response.Active != nil {
				want.Active = *item.Response.Active
			}
			got, err := client.SelectWorkspaceRepository(testContext(t), item.Request.Repositories, item.Request.Selected)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("selection = %#v, error = %v; want %#v", got, err, want)
			}
		})
	}
	duplicate := []WorkspaceRepository{
		{Path: "/w/a", ID: "a", Name: "a", Role: RepositoryNested},
		{Path: "/w/b", ID: "a", Name: "a", Role: RepositoryNested},
	}
	_, err = client.SelectWorkspaceRepository(testContext(t), duplicate, "")
	requireCode(t, err, CodeInvalidRequest)
}

func TestWorkspaceChangeGroupsUseCoreFixtures(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("git/workspace-change-groups-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				Repositories []WorkspaceRepositoryChanges `json:"repositories"`
			} `json:"request"`
			Response WorkspaceChangeGroups `json:"response"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the change group fixture has no cases")
	}
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			got, err := client.GroupWorkspaceChanges(testContext(t), item.Request.Repositories)
			if err != nil || !reflect.DeepEqual(got, item.Response) {
				t.Fatalf("groups = %#v, error = %v; want %#v", got, err, item.Response)
			}
		})
	}
}

func TestRepositoryColorAssignmentsUseCoreFixtures(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("git/repository-colors-v1.json"))
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
