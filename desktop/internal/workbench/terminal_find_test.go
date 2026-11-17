package workbench

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/text"
)

// Opening Find with a selection of one line searches for it, and the query is selected so
// that a paste replaces it.
func TestTerminalFindOpensWithTheSelectionSelected(t *testing.T) {
	var find terminalFind
	find.show("needle")
	if !find.open || !find.focus {
		t.Fatalf("show left open=%v focus=%v", find.open, find.focus)
	}
	if got := find.field.Text(); got != "needle" {
		t.Fatalf("query = %q, want the selected text", got)
	}
	if got, want := find.editor.Selection(), (text.Range{Start: 0, End: 6}); got != want {
		t.Fatalf("query selection = %+v, want %+v", got, want)
	}
}

// Opening again while the bar is open keeps what was typed, whatever is selected in the
// terminal now, and selects it.
func TestReopeningTerminalFindSelectsItsQuery(t *testing.T) {
	var find terminalFind
	find.show("")
	find.editor.Insert("typed")
	if got := find.editor.Selection(); got.Start != got.End {
		t.Fatalf("typing left %+v selected", got)
	}
	find.show("other")
	if got := find.field.Text(); got != "typed" {
		t.Fatalf("reopening replaced the query with %q", got)
	}
	if got, want := find.editor.Selection(), (text.Range{Start: 0, End: 5}); got != want {
		t.Fatalf("reopened selection = %+v, want %+v", got, want)
	}
}

// Find matches within a line, so a selection across a line break is no query; a long one
// is cut to the field's limit; trailing blanks are dropped.
func TestTerminalFindQueryFromASelection(t *testing.T) {
	long := strings.Repeat("界", terminalFindMaxQuery+10)
	tests := []struct {
		name, selected, want string
	}{
		{"word", "needle", "needle"},
		{"trailing blanks", "needle \t ", "needle"},
		{"two lines", "one\ntwo", ""},
		{"carriage return", "one\rtwo", ""},
		{"empty", "", ""},
		{"long", long, strings.Repeat("界", terminalFindMaxQuery)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := terminalFindQuery(test.selected); got != test.want {
				t.Fatalf("query %q, want %q", got, test.want)
			}
		})
	}
	var find terminalFind
	find.show("one\ntwo")
	if got := find.field.Text(); got != "" {
		t.Fatalf("a selection across lines filled the query with %q", got)
	}
}
