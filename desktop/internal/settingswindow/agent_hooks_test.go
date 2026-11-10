package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestHookMatchesSearchesTheFieldsTheRowShows(t *testing.T) {
	hook := core.AgentHook{
		ID: "hook-1", Name: "Format Go", Description: "gofmt after edits",
		Command: "gofmt -w .", Event: "after-tool",
	}
	for _, tc := range []struct {
		query string
		want  bool
	}{
		{"", true},
		{"format", true},
		{"GOFMT", true},
		{"after-tool", false}, // the raw event name is not shown; its label is searched
		{"Auto-format after tool", true},
		{"missing", false},
	} {
		label := "Auto-format after tool"
		if got := hookMatches(hook, label, foldQuery(tc.query)); got != tc.want {
			t.Errorf("query %q = %v, want %v", tc.query, got, tc.want)
		}
	}
}
