package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestWorkspaceFindAndWatchFollowTheLinkedCoreFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("workspace/find-watch-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Files       []struct{ Path, Text string }
		FileRequest WorkspaceFindRequest
		FilePaths   []string
		TextRequest WorkspaceFindRequest
		TextMatches []WorkspaceFindMatch
		Watch       struct {
			Paths    []string
			Expected WorkspaceWatchEvents
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for _, file := range fixture.Files {
		path := filepath.Join(root, filepath.FromSlash(file.Path))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(file.Text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	client := NewClient()
	collect := func(request WorkspaceFindRequest, text bool) []WorkspaceFindMatch {
		t.Helper()
		request.Root = root
		var matches []WorkspaceFindMatch
		for pageNumber := 0; pageNumber < 10; pageNumber++ {
			var page WorkspaceFindPage
			var err error
			if text {
				page, err = client.FindWorkspaceText(ctx, request)
			} else {
				page, err = client.FindWorkspaceFiles(ctx, request)
			}
			if err != nil || page.Source != "disk" || page.IsTruncated {
				t.Fatalf("page = %+v, error = %v", page, err)
			}
			matches = append(matches, page.Matches...)
			if page.NextCursor == nil {
				return matches
			}
			request.Cursor = page.NextCursor
		}
		t.Fatal("fixture search did not exhaust in ten pages")
		return nil
	}
	files := collect(fixture.FileRequest, false)
	var paths []string
	for _, file := range files {
		paths = append(paths, file.Path)
	}
	if !reflect.DeepEqual(paths, fixture.FilePaths) {
		t.Fatalf("files = %v, want %v", paths, fixture.FilePaths)
	}
	if matches := collect(fixture.TextRequest, true); !reflect.DeepEqual(matches, fixture.TextMatches) {
		t.Fatalf("text = %+v, want %+v", matches, fixture.TextMatches)
	}
	plan, err := client.PlanWorkspaceWatch(ctx, root, "", true)
	if err != nil || !plan.IsDirectory || !plan.Recursive {
		t.Fatalf("plan = %+v, %v", plan, err)
	}
	events, err := client.FilterWorkspaceWatchEvents(ctx, plan, fixture.Watch.Paths, false)
	if err != nil || !reflect.DeepEqual(events, fixture.Watch.Expected) {
		t.Fatalf("events = %+v, want %+v, %v", events, fixture.Watch.Expected, err)
	}
}
