package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// declaredFoldersManifest is the contract's static build system fixture under the fictional
// plugin id, its layout hiding the folders named names.
func declaredFoldersManifest(t *testing.T, id string, names ...string) json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(contractfixture.Path("fixtures/build-systems/build-static-file.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["id"] = id
	systems, _ := manifest["buildSystems"].([]any)
	if len(systems) == 0 {
		t.Fatal("the build system fixture declares no build system")
	}
	system := systems[0].(map[string]any)
	layout, _ := system["layout"].(map[string]any)
	if layout == nil {
		layout = map[string]any{}
	}
	layout["hiddenDirectoryNames"] = names
	system["layout"] = layout
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

// childNames lists the names in the folder at path of root, in Core's order.
func childNames(t *testing.T, client *Client, ctx context.Context, root, path string) []string {
	t.Helper()
	listings, err := client.ListDirectories(ctx, root, []string{path})
	if err != nil || len(listings) != 1 {
		t.Fatalf("listing %q = %+v, %v", path, listings, err)
	}
	names := []string{}
	for _, child := range listings[0].Children {
		names = append(names, child.Name)
	}
	return names
}

// matchPaths is the files a search for the needle finds in root.
func matchPaths(t *testing.T, client *Client, ctx context.Context, root string) []string {
	t.Helper()
	matches, err := client.SearchWorkspace(ctx, WorkspaceSearchRequest{Root: root, Query: "distinctive needle", MaxResults: 20})
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{}
	for _, match := range matches {
		paths = append(paths, match.Path)
	}
	return paths
}

// Core hides its own folders, such as .worktrees, by itself, and the folders an enabled
// plugin's build system names at any depth and in any ASCII case once it is handed the
// manifest. A manifest it rejects hides nothing, and an empty call shows the folders again.
func TestWorkspaceVisibilityHidesTheFoldersPluginsDeclare(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"fixture-out", "nested/Fixture-Out", ".worktrees", "src"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, dir, "hidden.txt"), []byte("distinctive needle"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	client := NewClient()
	ctx := testContext(t)
	t.Cleanup(func() {
		if _, err := client.ConfigureVisibility(context.Background(), nil); err != nil {
			t.Errorf("clearing the hidden folders: %v", err)
		}
	})

	configuration, err := client.ConfigureVisibility(ctx, []json.RawMessage{
		declaredFoldersManifest(t, "dev.lithe.test.declared-folders", "fixture-out"),
		declaredFoldersManifest(t, "dev.lithe.test.invalid-folder-name", "fixture/out"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(configuration.HiddenDirectoryNames, []string{"fixture-out"}) || len(configuration.Rejected) != 1 || configuration.Rejected[0].Index != 1 {
		t.Fatalf("configureVisibility = %+v", configuration)
	}
	if got := childNames(t, client, ctx, root, ""); !reflect.DeepEqual(got, []string{"nested", "src"}) {
		t.Fatalf("root entries = %v", got)
	}
	if got := childNames(t, client, ctx, root, "nested"); len(got) != 0 {
		t.Fatalf("nested entries = %v, want the declared folder hidden", got)
	}
	if got := matchPaths(t, client, ctx, root); !reflect.DeepEqual(got, []string{"src/hidden.txt"}) {
		t.Fatalf("search matches = %v", got)
	}

	cleared, err := client.ConfigureVisibility(ctx, nil)
	if err != nil || len(cleared.HiddenDirectoryNames) != 0 || len(cleared.Rejected) != 0 {
		t.Fatalf("clearing = %+v, %v", cleared, err)
	}
	if got := childNames(t, client, ctx, root, ""); !reflect.DeepEqual(got, []string{"fixture-out", "nested", "src"}) {
		t.Fatalf("root entries after clearing = %v", got)
	}
	if got := matchPaths(t, client, ctx, root); len(got) != 3 {
		t.Fatalf("search matches after clearing = %v, want the three visible files", got)
	}
}
