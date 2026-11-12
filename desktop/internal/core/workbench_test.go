package core

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestReduceEditorWorkbench(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)

	reduce := func(t *testing.T, state EditorWorkbench, action EditorAction) (EditorWorkbench, []string) {
		t.Helper()
		next, removed, err := client.ReduceEditorWorkbench(ctx, state, action)
		if err != nil {
			t.Fatalf("ReduceEditorWorkbench() error: %v", err)
		}
		return next, removed
	}

	tool := EditorWorkbench{Groups: []EditorGroup{{ID: "tool"}}}

	t.Run("open adds the member and selects it", func(t *testing.T) {
		state, _ := reduce(t, tool, OpenEditor("tool", "terminal:1", true))
		state, _ = reduce(t, state, OpenEditor("tool", "terminal:2", true))
		g := state.Group("tool")
		if g == nil || !slices.Equal(g.Members, []string{"terminal:1", "terminal:2"}) || g.Selected != "terminal:2" {
			t.Fatalf("tool = %+v, want both terminals with the second selected", g)
		}
	})

	t.Run("close keeps an empty tool group", func(t *testing.T) {
		state, _ := reduce(t, tool, OpenEditor("tool", "terminal:1", true))
		state, removed := reduce(t, state, CloseEditor("tool", "terminal:1", KeepEmptyGroups, SelectAdjacent))
		if g := state.Group("tool"); g == nil || len(g.Members) != 0 || g.Selected != "" {
			t.Fatalf("tool = %+v, want an empty group", g)
		}
		if len(removed) != 0 {
			t.Errorf("removed = %q, want none", removed)
		}
	})

	t.Run("a move that empties a split removes it", func(t *testing.T) {
		state := EditorWorkbench{Groups: []EditorGroup{
			{ID: "a", Members: []string{"terminal:1"}, Selected: "terminal:1", MRU: []string{"terminal:1"}},
			{ID: "b", Members: []string{"terminal:2"}, Selected: "terminal:2", MRU: []string{"terminal:2"}},
		}}
		state, removed := reduce(t, state, MoveEditor(EditorMove{
			Member: "terminal:2", From: "b", To: "a", Before: "terminal:1",
			Activate: true, Empty: RemoveEmptyGroups, Fallback: SelectAdjacent,
		}))
		if !slices.Equal(removed, []string{"b"}) {
			t.Errorf("removed = %q, want [b]", removed)
		}
		g := state.Group("a")
		if g == nil || !slices.Equal(g.Members, []string{"terminal:2", "terminal:1"}) || g.Selected != "terminal:2" {
			t.Fatalf("a = %+v, want terminal:2 before terminal:1, selected", g)
		}
		if state.Group("b") != nil {
			t.Errorf("groups = %+v, want b gone", state.Groups)
		}
	})

	t.Run("a move into a new group the host added", func(t *testing.T) {
		state := EditorWorkbench{Groups: []EditorGroup{
			{ID: "a", Members: []string{"terminal:1", "terminal:2"}, Selected: "terminal:2"},
			{ID: "c"},
		}}
		state, _ = reduce(t, state, MoveEditor(EditorMove{
			Member: "terminal:2", From: "a", To: "c", Activate: true,
			Empty: RemoveEmptyGroups, Fallback: SelectAdjacent,
		}))
		if g := state.Group("c"); g == nil || !slices.Equal(g.Members, []string{"terminal:2"}) || g.Selected != "terminal:2" {
			t.Fatalf("c = %+v, want terminal:2 selected", g)
		}
		if g := state.Group("a"); g == nil || g.Selected != "terminal:1" {
			t.Fatalf("a = %+v, want terminal:1 selected after its selection left", g)
		}
		if got := state.GroupOf("terminal:2"); got == nil || got.ID != "c" {
			t.Errorf("GroupOf(terminal:2) = %+v, want c", got)
		}
	})

	t.Run("reorder and merge", func(t *testing.T) {
		state := EditorWorkbench{Groups: []EditorGroup{
			{ID: "a", Members: []string{"terminal:1", "terminal:2", "terminal:3"}, Selected: "terminal:1"},
			{ID: "b", Members: []string{"terminal:4"}, Selected: "terminal:4"},
		}}
		state, _ = reduce(t, state, ReorderEditor("a", 0, 2))
		if g := state.Group("a"); !slices.Equal(g.Members, []string{"terminal:2", "terminal:3", "terminal:1"}) {
			t.Fatalf("reordered = %q", g.Members)
		}
		state, removed := reduce(t, state, MergeEditorGroups("b", "a", true))
		if !slices.Equal(removed, []string{"b"}) {
			t.Errorf("removed = %q, want [b]", removed)
		}
		if g := state.Group("a"); g == nil || len(g.Members) != 4 || g.Selected != "terminal:4" {
			t.Fatalf("merged = %+v, want four members with terminal:4 selected", g)
		}
	})

	t.Run("activate and normalize", func(t *testing.T) {
		state := EditorWorkbench{Groups: []EditorGroup{{ID: "a", Members: []string{"terminal:1", "terminal:2"}}}}
		state, _ = reduce(t, state, ActivateEditor("a", "terminal:1"))
		if g := state.Group("a"); g.Selected != "terminal:1" {
			t.Fatalf("selected = %q, want terminal:1", g.Selected)
		}
		state.Groups = append(state.Groups, EditorGroup{ID: "empty"})
		state, removed := reduce(t, state, NormalizeEditor(RemoveEmptyGroups, nil))
		if !slices.Equal(removed, []string{"empty"}) || state.Group("empty") != nil {
			t.Errorf("normalize removed %q, groups %+v; want the empty group gone", removed, state.Groups)
		}
	})

	t.Run("an unknown group changes nothing", func(t *testing.T) {
		state, removed := reduce(t, tool, OpenEditor("missing", "terminal:1", true))
		if len(state.Groups) != 1 || len(state.Groups[0].Members) != 0 || len(removed) != 0 {
			t.Fatalf("state = %+v, removed %q; want it unchanged", state, removed)
		}
	})
}

func TestEditorActionEncoding(t *testing.T) {
	if _, err := json.Marshal(EditorAction{}); err == nil {
		t.Error("zero EditorAction encoded, want an error")
	}
	cases := []struct {
		action EditorAction
		want   string
	}{
		{ActivateEditor("a", ""), `{"kind":"activate","group":"a","member":null}`},
		{MoveEditor(EditorMove{Member: "m", From: "a", To: "b"}), `{"kind":"move","member":"m","from":"a","to":"b","activate":false}`},
		{NormalizeEditor("", nil), `{"kind":"normalize","unplaced":[]}`},
		{MergeEditorGroups("a", "b", true), `{"kind":"mergeGroup","from":"a","into":"b","activateSelected":true}`},
	}
	for _, c := range cases {
		got, err := json.Marshal(c.action)
		if err != nil {
			t.Fatalf("Marshal(%+v) error: %v", c.action, err)
		}
		if string(got) != c.want {
			t.Errorf("Marshal = %s, want %s", got, c.want)
		}
	}
	state, err := json.Marshal(EditorWorkbench{Groups: []EditorGroup{{ID: "a"}}})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"groups":[{"id":"a","members":[],"mru":[],"pinned":[]}]}`; string(state) != want {
		t.Errorf("state = %s, want %s", state, want)
	}
}
