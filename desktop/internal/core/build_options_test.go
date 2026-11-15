package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// emptyBuildLocal is the local Build document of a project that stores nothing.
var emptyBuildLocal = json.RawMessage(`{"version":1,"document":{"version":1,"systems":{}}}`)

// The ignored paths come from the local document, else the team document, else Core's default of every
// dot-named directory. An edit replaces the local list, an empty list included, or removes it so the
// team's applies again; Core names the first pattern it does not accept.
func TestBuildIgnoredPathsResolveFromTheLayersAndEditTheLocalList(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	noTeam := json.RawMessage(`{"version":1,"systems":{}}`)
	team := json.RawMessage(`{"version":1,"systems":{},"ignoredPaths":["vendor/"]}`)
	resolved := func(document, local json.RawMessage) BuildIgnoredPaths {
		t.Helper()
		storage, err := client.ResolveStoredBuildOptions(ctx, document, local)
		if err != nil {
			t.Fatal(err)
		}
		return storage.IgnoredPaths
	}
	if got := resolved(noTeam, emptyBuildLocal); !slices.Equal(got.Patterns, []string{".*"}) || got.Source != BuildIgnoredPathsDefault {
		t.Fatalf("without a stored list the ignored paths are %+v, want Core's default", got)
	}
	if got := resolved(team, emptyBuildLocal); !slices.Equal(got.Patterns, []string{"vendor/"}) || got.Source != BuildIgnoredPathsTeam {
		t.Fatalf("with the team's list the ignored paths are %+v", got)
	}

	edit, err := client.EditBuildIgnoredPaths(ctx, BuildIgnoredPathsEditRequest{Document: team, Local: emptyBuildLocal, Patterns: []string{".*", "!.config"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := edit.IgnoredPaths; !slices.Equal(got.Patterns, []string{".*", "!.config"}) || got.Source != BuildIgnoredPathsLocal {
		t.Fatalf("after the edit the ignored paths are %+v", got)
	}
	if got := resolved(team, edit.Local); !slices.Equal(got.Patterns, []string{".*", "!.config"}) || got.Source != BuildIgnoredPathsLocal {
		t.Fatalf("the edited local document resolves to %+v", got)
	}

	// No patterns is the choice to ignore nothing, which is kept, not the default.
	none, err := client.EditBuildIgnoredPaths(ctx, BuildIgnoredPathsEditRequest{Document: team, Local: edit.Local})
	if err != nil {
		t.Fatal(err)
	}
	if got := resolved(team, none.Local); got.Patterns == nil || len(got.Patterns) != 0 || got.Source != BuildIgnoredPathsLocal {
		t.Fatalf("an empty local list resolves to %+v, want an empty list from the local document", got)
	}

	inherited, err := client.EditBuildIgnoredPaths(ctx, BuildIgnoredPathsEditRequest{Document: team, Local: none.Local, Inherit: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := inherited.IgnoredPaths; !slices.Equal(got.Patterns, []string{"vendor/"}) || got.Source != BuildIgnoredPathsTeam {
		t.Fatalf("removing the local list leaves %+v, want the team's", got)
	}

	_, err = client.EditBuildIgnoredPaths(ctx, BuildIgnoredPathsEditRequest{Document: team, Local: emptyBuildLocal, Patterns: []string{".*", "# note"}})
	var rejection *MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.build.invalidIgnoredPath" || rejection.Field != "ignoredPaths[1]" {
		t.Fatalf("a comment line answered %v, want plugin.build.invalidIgnoredPath at ignoredPaths[1]", err)
	}
}

// Detection skips every dot-named directory unless it is given the list to use; an empty list ignores
// nothing beyond the shared scan policy.
func TestBuildDetectSkipsTheIgnoredPaths(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root := t.TempDir()
	for _, dir := range []string{".", ".claude/copy", "tools"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, dir, "Cargo.toml"), []byte("[package]\nname = \"app\"\nversion = \"0.1.0\"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/build-systems/build-static-file.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	roots := func(ignored []string) []string {
		t.Helper()
		detection, err := client.DetectBuildSystemsWithOptions(ctx, root, []json.RawMessage{manifest}, BuildDetectOptions{IgnoredPaths: ignored})
		if err != nil {
			t.Fatal(err)
		}
		var roots []string
		for _, instance := range detection.Instances {
			roots = append(roots, instance.Root)
		}
		slices.Sort(roots)
		return roots
	}
	if got := roots(nil); !slices.Equal(got, []string{".", "tools"}) {
		t.Fatalf("by default detection finds %q, want the dot-named directory skipped", got)
	}
	if got := roots([]string{}); !slices.Equal(got, []string{".", ".claude/copy", "tools"}) {
		t.Fatalf("ignoring nothing detection finds %q", got)
	}
	if got := roots([]string{"/tools"}); !slices.Equal(got, []string{".", ".claude/copy"}) {
		t.Fatalf("ignoring /tools detection finds %q", got)
	}
}
