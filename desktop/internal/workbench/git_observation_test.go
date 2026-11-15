package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A flood of changed paths turns into one full rescan instead of an unbounded list.
func TestGitObservationFloodBecomesFullRescan(t *testing.T) {
	a := &App{}
	p := &project{root: t.TempDir()}
	for i := 0; i <= gitObserveMaxPaths; i++ {
		a.addGitPath(p, "x")
	}
	if !p.observe.full || len(p.observe.paths) != 0 {
		t.Fatalf("flood = full %v, %d paths; want a full rescan with no paths", p.observe.full, len(p.observe.paths))
	}
}

// An index-only metadata write refreshes the status but not the history, so staging does not
// refresh the blame; a commit or ref move does both; a repository move restarts the watch.
func TestGitScopeSeparatesIndexFromHistory(t *testing.T) {
	cases := []struct {
		name   string
		events []core.GitMetadataEvent
		want   gitChangeScope
	}{
		{"index only", []core.GitMetadataEvent{{Kind: "metadata", IndexOnly: true}}, gitChangeScope{status: true}},
		{"commit", []core.GitMetadataEvent{{Kind: "metadata"}}, gitChangeScope{status: true, history: true}},
		{"repository moved", []core.GitMetadataEvent{{Kind: "context"}}, gitChangeScope{restart: true}},
		{"nothing relevant", []core.GitMetadataEvent{{Kind: "ignored"}}, gitChangeScope{}},
		{"classification failed", nil, gitChangeScope{status: true, history: true}},
	}
	for _, tc := range cases {
		err := error(nil)
		if tc.name == "classification failed" {
			err = errTest
		}
		if got := gitScopeOf(tc.events, err); got != tc.want {
			t.Errorf("%s: scope = %+v, want %+v", tc.name, got, tc.want)
		}
	}
}

var errTest = errorString("classify failed")

type errorString string

func (e errorString) Error() string { return string(e) }
