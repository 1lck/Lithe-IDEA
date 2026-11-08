package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestEverywhereSearchPagesUseCoreRankingAndContext(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/search/search-everywhere-context-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID            string                   `json:"id"`
			Files         []string                 `json:"files"`
			Query         string                   `json:"query"`
			Context       *EverywhereSearchContext `json:"context"`
			ExpectedPaths []string                 `json:"expectedPaths"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, test := range fixture.Cases {
		t.Run(test.ID, func(t *testing.T) {
			root := t.TempDir()
			for _, relative := range test.Files {
				file := filepath.Join(root, filepath.FromSlash(relative))
				if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(file, []byte("content-only-needle\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			client := NewClient()
			request := EverywhereSearchRequest{Root: root, Query: test.Query, PageSize: 2, ResultKinds: []string{"file"}, IncludeGeneratedFileNames: true, Context: test.Context}
			var got []string
			for pageNumber := 0; pageNumber < 10; pageNumber++ {
				page, err := client.SearchEverywherePage(ctx, request)
				if err != nil {
					t.Fatal(err)
				}
				if len(page.Matches) > request.PageSize {
					t.Fatalf("page has %d results, want at most %d", len(page.Matches), request.PageSize)
				}
				for _, match := range page.Matches {
					if match.Kind != "file" {
						t.Fatalf("unexpected result kind: %+v", match)
					}
					got = append(got, match.Path)
				}
				if page.NextCursor == nil {
					break
				}
				if request.Cursor != nil && *page.NextCursor == *request.Cursor {
					t.Fatal("Core repeated the page cursor")
				}
				request.Cursor = page.NextCursor
				if pageNumber == 9 {
					t.Fatal("Core did not exhaust the search pages")
				}
			}
			if !reflect.DeepEqual(got, test.ExpectedPaths) {
				t.Fatalf("ranked paths = %v, want %v", got, test.ExpectedPaths)
			}
			request.Query, request.Cursor = "content-only-needle", nil
			page, err := client.SearchEverywherePage(ctx, request)
			if err != nil || len(page.Matches) != 0 {
				t.Fatalf("file-only search returned content matches: %+v, %v", page, err)
			}
			if err := client.InvalidateWorkspaceSearch(ctx, root); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func BenchmarkEverywhereSearchIndex(b *testing.B) {
	root := b.TempDir()
	for i := 0; i < 2000; i++ {
		name := filepath.Join(root, fmt.Sprintf("file-%04d.go", i))
		if err := os.WriteFile(name, []byte("package sample\n"), 0o600); err != nil {
			b.Fatal(err)
		}
	}
	client := NewClient()
	request := EverywhereSearchRequest{Root: root, Query: "file", PageSize: 50, ResultKinds: []string{"file"}, IncludeGeneratedFileNames: true}
	ctx := context.Background()
	if _, err := client.SearchEverywherePage(ctx, request); err != nil {
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
				if _, err := client.SearchEverywherePage(ctx, request); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
