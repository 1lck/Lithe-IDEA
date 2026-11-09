package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The desktop tree displays Core's order directly on both platforms. The
// release-notes fixture avoids case-only names, which cannot coexist on the
// default Windows and macOS filesystems.
func TestWorkspaceDirectoryTreeUsesCoreNaturalOrder(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/workspace/file-name-order-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Groups []struct {
			ID    string   `json:"id"`
			Names []string `json:"names"`
		} `json:"orderedGroups"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, group := range fixture.Groups {
		if group.ID == "release-notes" {
			names = group.Names
		}
	}
	if len(names) == 0 {
		t.Fatal("release-notes order fixture is empty")
	}
	root := t.TempDir()
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(root, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, "z-folder"), 0o700); err != nil {
		t.Fatal(err)
	}
	listings, err := NewClient().ListDirectories(testContext(t), root, []string{""})
	if err != nil {
		t.Fatal(err)
	}
	if len(listings) != 1 {
		t.Fatalf("got %d directory listings, want one", len(listings))
	}
	var got []string
	for _, child := range listings[0].Children {
		got = append(got, child.Name)
	}
	want := append([]string{"z-folder"}, names...)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("directory order = %v, want %v", got, want)
	}
}

func TestWorkspaceDirectoryAndSearchHidePythonEnvironments(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{".venv", "venv", "__pycache__"} {
		if err := os.Mkdir(filepath.Join(root, dir), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, dir, "hidden.py"), []byte("distinctive needle"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"main.py", "compiled.pyc"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("distinctive needle"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	client := NewClient()
	ctx := testContext(t)
	listings, err := client.ListDirectories(ctx, root, []string{""})
	if err != nil || len(listings) != 1 || len(listings[0].Children) != 1 || listings[0].Children[0].Name != "main.py" {
		t.Fatalf("visible directory entries = %+v, error = %v", listings, err)
	}
	matches, err := client.SearchWorkspace(ctx, WorkspaceSearchRequest{Root: root, Query: "distinctive needle", MaxResults: 20})
	if err != nil || len(matches) != 1 || matches[0].Path != "main.py" {
		t.Fatalf("search matches = %+v, error = %v", matches, err)
	}
}
