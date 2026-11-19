package core

import (
	"context"
	"os"
	"testing"
	"time"
)

// BenchmarkWorkspaceColdContentSearch compares the sidebar and popup on the same real checkout.
// An explicit root avoids treating a small generated workspace as a large-project measurement.
func BenchmarkWorkspaceColdContentSearch(b *testing.B) {
	root := os.Getenv("LITHE_SEARCH_BENCH_ROOT")
	if root == "" {
		b.Skip("set LITHE_SEARCH_BENCH_ROOT to a real workspace")
	}
	query := "LockOSThread"
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	status, err := client.ConfigureIndexing(ctx, root, "search-latency-benchmark", IndexingPolicyOf(nil, true), false)
	cancel()
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := client.ReleaseIndexing(ctx, root, "search-latency-benchmark", status.Revision); err != nil {
			b.Error(err)
		}
	})
	for _, popup := range []bool{false, true} {
		name := "sidebar"
		if popup {
			name = "popup-text"
		}
		b.Run(name, func(b *testing.B) {
			for b.Loop() {
				ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
				if err := client.InvalidateWorkspaceSearch(ctx, root); err != nil {
					cancel()
					b.Fatal(err)
				}
				var count int
				var err error
				if popup {
					var page EverywhereSearchPage
					page, err = client.SearchEverywherePage(ctx, EverywhereSearchRequest{Root: root, Query: query, PageSize: 50, ResultKinds: []string{"content"}, IncludeContentRanges: true, MaxFileBytes: 16 << 20})
					count = len(page.Matches)
				} else {
					var page WorkspaceSearchPage
					page, err = client.SearchWorkspacePage(ctx, WorkspaceSearchRequest{Root: root, Query: query, PageSize: 50, IncludeContentRanges: true, MaxFileBytes: 16 << 20})
					count = len(page.Matches)
				}
				cancel()
				if err != nil || count == 0 {
					b.Fatalf("real search returned %d matches: %v", count, err)
				}
			}
		})
	}
}
