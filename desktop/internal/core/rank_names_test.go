package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestRankNamesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("search/rank-names-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID      string `json:"id"`
			Request struct {
				Query      string          `json:"query"`
				Candidates []RankCandidate `json:"candidates"`
			} `json:"request"`
			Expected []struct {
				Index int `json:"index"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		switch c.ID {
		case "camel-hump-initials-find-the-class-file", "exact-beats-prefix-beats-substring", "name-match-beats-path-only-match", "blank-query-matches-nothing":
		default:
			continue
		}
		t.Run(c.ID, func(t *testing.T) {
			got, err := client.RankNames(testContext(t), c.Request.Query, c.Request.Candidates)
			if err != nil {
				t.Fatal(err)
			}
			want := make([]int, 0, len(c.Expected))
			for _, item := range c.Expected {
				want = append(want, item.Index)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("ranked indices = %v, want %v", got, want)
			}
		})
	}
}

// A fixed synthetic catalog keeps the Core boundary cost comparable when the
// marketplace search changes. Go allocation figures exclude Core's allocator.
func BenchmarkRankNamesMarketplace1000(b *testing.B) {
	client := NewClient()
	candidates := make([]RankCandidate, 1000)
	for i := range candidates {
		candidates[i] = RankCandidate{Name: fmt.Sprintf("Plugin %04d Cargo", i), Path: fmt.Sprintf("io.example.plugin-%04d", i)}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := client.RankNames(context.Background(), "cargo", candidates); err != nil {
			b.Fatal(err)
		}
	}
}
