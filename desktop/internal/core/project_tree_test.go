package core

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestReduceRowSelection(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	rows := []string{"", "a", "a/x", "b", "c"}
	reduce := func(t *testing.T, selection RowSelection, action RowAction) RowSelectionResult {
		t.Helper()
		result, err := client.ReduceRowSelection(ctx, rows, selection, action)
		if err != nil {
			t.Fatalf("ReduceRowSelection() error: %v", err)
		}
		return result
	}

	t.Run("a Shift click marks from the anchor and keeps the other marks", func(t *testing.T) {
		result := reduce(t, RowSelection{Selected: new("a"), Marked: []string{"c"}, Anchor: "a/x"}, ExtendRow("b"))
		if s := result.Selection; s.Selected == nil || *s.Selected != "b" || s.Anchor != "a/x" || !slices.Equal(s.Marked, []string{"a/x", "b", "c"}) {
			t.Fatalf("selection = %+v, want b selected, a/x to c marked, anchor kept", s)
		}
	})

	t.Run("a marked folder stands for its contents", func(t *testing.T) {
		result := reduce(t, RowSelection{Selected: new("b")}, ExtendRow("a"))
		if !slices.Equal(result.Targets, []string{"a", "b"}) {
			t.Fatalf("targets = %v, want a and b", result.Targets)
		}
	})

	t.Run("the root is never marked", func(t *testing.T) {
		result := reduce(t, RowSelection{Selected: new("a")}, ToggleRow(""))
		if len(result.Selection.Marked) != 0 || *result.Selection.Selected != "a" {
			t.Fatalf("selection = %+v, want it unchanged", result.Selection)
		}
	})

	t.Run("clear keeps the selected row", func(t *testing.T) {
		result := reduce(t, RowSelection{Selected: new("b"), Marked: []string{"a", "b"}, Anchor: "a"}, ClearRows())
		if s := result.Selection; *s.Selected != "b" || len(s.Marked) != 0 || s.Anchor != "" || result.Targets == nil {
			t.Fatalf("selection = %+v, targets %v; want b alone and no targets", s, result.Targets)
		}
	})

	t.Run("a click on a row that went away is stale", func(t *testing.T) {
		if got := reduce(t, RowSelection{}, ChooseRow("gone")).Rejection; got != RowSelectionStale {
			t.Fatalf("rejection = %q, want %q", got, RowSelectionStale)
		}
	})
}

func TestProjectTreeRows(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	nodes := []ProjectTreeNode{
		{Path: "", Depth: 0, Open: true},
		{Path: "a", Depth: 1},
		{Path: "a/x", Depth: 2},
		{Path: "b", Depth: 1},
	}
	result, err := client.ProjectTreeRows(ctx, ProjectTreeQuery{
		Nodes:     nodes,
		Selection: RowSelection{Selected: new("a/x"), Marked: []string{"a/x", "gone"}},
		Top:       new("b"),
	})
	if err != nil {
		t.Fatalf("ProjectTreeRows() error: %v", err)
	}
	if !slices.Equal(result.Rows, []int{0, 1, 3}) {
		t.Errorf("rows = %v, want the root, a and b", result.Rows)
	}
	if s := result.Selection; !result.SelectionMoved || s.Selected == nil || *s.Selected != "a" || !slices.Equal(s.Marked, []string{"a/x"}) {
		t.Errorf("selection = %+v moved %v, want a, the hidden mark kept and the gone one dropped", s, result.SelectionMoved)
	}
	if result.TopRow == nil || *result.TopRow != 2 {
		t.Errorf("top row = %v, want 2", result.TopRow)
	}
	if _, err := client.ProjectTreeRows(ctx, ProjectTreeQuery{Nodes: nodes[1:]}); err == nil {
		t.Error("nodes without the root were accepted")
	}
}

func TestRowActionEncoding(t *testing.T) {
	cases := []struct {
		action RowAction
		want   string
	}{
		{ChooseRow("a"), `{"kind":"choose","path":"a"}`},
		{ToggleRow(""), `{"kind":"toggle","path":""}`},
		{ExtendRow("b"), `{"kind":"extend","path":"b"}`},
		{ClearRows(), `{"kind":"clear"}`},
		{RowAction{}, `{"kind":"clear"}`},
	}
	for _, c := range cases {
		got, err := json.Marshal(c.action)
		if err != nil || string(got) != c.want {
			t.Errorf("Marshal = %s, %v; want %s", got, err, c.want)
		}
	}
	got, _ := json.Marshal(RowSelection{})
	if want := `{"selected":null}`; string(got) != want {
		t.Errorf("empty selection = %s, want %s", got, want)
	}
}
