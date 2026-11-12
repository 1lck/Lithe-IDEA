package core

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWorkspaceSearchUsesCoreOptionsAndRefreshesChanges(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "example.go")
	if err := os.WriteFile(path, []byte("alpha needle\nBeta NEEDLE\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "other.txt"), []byte("needle\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := NewClient()
	request := WorkspaceSearchRequest{Root: root, Query: "needle", CaseSensitive: true, FileMask: "*.go", MaxResults: 100}
	matches, err := client.SearchWorkspace(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 || matches[0].Path != "example.go" || matches[0].Line == nil || *matches[0].Line != 1 {
		t.Fatalf("search results = %+v", matches)
	}
	if err := os.WriteFile(path, []byte("new external value\n"), 0600); err != nil {
		t.Fatal(err)
	}
	filtered, err := client.FilterWorkspaceChanges(ctx, []string{"node_modules/ignored.js", "example.go"})
	if err != nil || len(filtered) != 1 || filtered[0] != "example.go" {
		t.Fatalf("filtered changes = %v, %v", filtered, err)
	}
	if err := client.UpdateWorkspaceSearch(ctx, root, filtered); err != nil {
		t.Fatal(err)
	}
	request.Query = "external"
	matches, err = client.SearchWorkspace(ctx, request)
	if err != nil || len(matches) != 1 || matches[0].Line == nil || *matches[0].Line != 1 {
		t.Fatalf("refreshed results = %+v, %v", matches, err)
	}
	if err := client.InvalidateWorkspaceSearch(ctx, root); err != nil {
		t.Fatal(err)
	}
}

// BenchmarkWorkspaceSearchIndex compares a fresh index with Core's reusable
// index on a bounded workspace, so the cost of refreshing can be measured.
func BenchmarkWorkspaceSearchIndex(b *testing.B) {
	root := b.TempDir()
	for i := 0; i < 2000; i++ {
		name := filepath.Join(root, fmt.Sprintf("file-%04d.go", i))
		if err := os.WriteFile(name, []byte("package sample\n// searchable needle in a small source file\n"), 0o600); err != nil {
			b.Fatal(err)
		}
	}
	client := NewClient()
	request := WorkspaceSearchRequest{Root: root, Query: "needle", MaxResults: 200}
	ctx := context.Background()
	if _, err := client.SearchWorkspace(ctx, request); err != nil {
		b.Fatal(err)
	}
	for _, cold := range []bool{false, true} {
		name := "warm"
		if cold {
			name = "rebuild"
		}
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if cold {
					if err := client.InvalidateWorkspaceSearch(ctx, root); err != nil {
						b.Fatal(err)
					}
				}
				if _, err := client.SearchWorkspace(ctx, request); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
