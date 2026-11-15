package core

import (
	"encoding/json"
	"slices"
	"testing"
)

// leafGroups are the groups of a layout, first to last.
func leafGroups(l *EditorLayout) []string {
	if l == nil {
		return nil
	}
	if l.Group != "" {
		return []string{l.Group}
	}
	return append(leafGroups(l.First), leafGroups(l.Second)...)
}

func TestReduceEditorLayout(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	reduce := func(t *testing.T, state EditorWorkbench, layout *EditorLayout, action EditorAction) EditorLayoutResult {
		t.Helper()
		result, err := client.ReduceEditorLayout(ctx, state, layout, action)
		if err != nil {
			t.Fatalf("ReduceEditorLayout() error: %v", err)
		}
		return result
	}
	docked := []string{"tool"}
	twoTerminals := EditorWorkbench{Groups: []EditorGroup{
		{ID: "tool", Members: []string{"terminal:1", "terminal:2"}, Selected: "terminal:1"},
		{ID: "editor:1", Members: []string{"document:1"}, Selected: "document:1"},
	}}
	one := &EditorLayout{Group: "editor:1"}

	t.Run("openTab makes the first group of an empty editor", func(t *testing.T) {
		result := reduce(t, EditorWorkbench{}, nil, OpenEditorTab("document:1", "", "editor:1"))
		if result.Group != "editor:1" || !slices.Equal(leafGroups(result.Layout), []string{"editor:1"}) {
			t.Fatalf("result = %+v, want document:1 in a new editor:1 that fills the layout", result)
		}
		if g := result.State.Group("editor:1"); g == nil || g.Selected != "document:1" {
			t.Fatalf("editor:1 = %+v, want document:1 selected", g)
		}
	})

	t.Run("openTab prefers a group the layout shows", func(t *testing.T) {
		state := twoTerminals
		state.Groups = append(slices.Clone(state.Groups), EditorGroup{ID: "editor:2", Members: []string{"document:2"}})
		layout := &EditorLayout{Node: 1, Row: true, First: &EditorLayout{Group: "editor:1"}, Second: &EditorLayout{Group: "editor:2"}}
		if got := reduce(t, state, layout, OpenEditorTab("document:3", "editor:2", "editor:3")).Group; got != "editor:2" {
			t.Errorf("preferred editor:2: group = %q", got)
		}
		if got := reduce(t, state, layout, OpenEditorTab("document:3", "editor:9", "editor:3")).Group; got != "editor:1" {
			t.Errorf("missing preference: group = %q, want the first group", got)
		}
	})

	t.Run("a terminal splits the editor and the docked group stays", func(t *testing.T) {
		result := reduce(t, twoTerminals, one, DropEditorTab(EditorDrop{
			Member: "terminal:1", Target: SplitEditorGroup("editor:1", EditorEdgeLeft),
			Docked: docked, Dockable: true, NewGroup: "editor:2", NewNode: 4,
		}))
		if result.Rejection != "" || result.Group != "editor:2" {
			t.Fatalf("result = %+v, want the terminal in editor:2", result)
		}
		l := result.Layout
		if l == nil || l.Node != 4 || !l.Row || !slices.Equal(leafGroups(l), []string{"editor:2", "editor:1"}) {
			t.Fatalf("layout = %+v, want split 4 with editor:2 left of editor:1", l)
		}
		if g := result.State.Group("tool"); g == nil || !slices.Equal(g.Members, []string{"terminal:2"}) {
			t.Fatalf("tool = %+v, want terminal:2 left", g)
		}
	})

	t.Run("the last tab of a split leaves it and the sibling takes the room", func(t *testing.T) {
		state := twoTerminals
		state.Groups = append(slices.Clone(state.Groups), EditorGroup{ID: "editor:2", Members: []string{"document:2"}, Selected: "document:2"})
		layout := &EditorLayout{Node: 1, First: &EditorLayout{Group: "editor:1"}, Second: &EditorLayout{Group: "editor:2"}}
		result := reduce(t, state, layout, DropEditorTab(EditorDrop{
			Member: "document:2", Target: JoinEditorGroup("editor:1", 0), Docked: docked,
		}))
		if !slices.Equal(result.Removed, []string{"editor:2"}) || !slices.Equal(leafGroups(result.Layout), []string{"editor:1"}) {
			t.Fatalf("result = %+v, want editor:2 gone from the state and the layout", result)
		}
	})

	t.Run("a file cannot join the docked group", func(t *testing.T) {
		result := reduce(t, twoTerminals, one, DropEditorTab(EditorDrop{
			Member: "document:1", Target: JoinEditorGroup("tool", 0), Docked: docked,
		}))
		if result.Rejection != EditorDropRefused {
			t.Fatalf("rejection = %q, want %q", result.Rejection, EditorDropRefused)
		}
	})

	t.Run("a drop of a closed tab is stale", func(t *testing.T) {
		result := reduce(t, twoTerminals, one, DropEditorTab(EditorDrop{
			Member: "terminal:9", Target: JoinEditorGroup("editor:1", 0), Docked: docked, Dockable: true,
		}))
		if result.Rejection != EditorDropStale {
			t.Fatalf("rejection = %q, want %q", result.Rejection, EditorDropStale)
		}
	})

	t.Run("removeEmptyGroups drops only the named empty groups", func(t *testing.T) {
		state := twoTerminals
		state.Groups = append(slices.Clone(state.Groups), EditorGroup{ID: "editor:2"}, EditorGroup{ID: "editor:3"})
		layout := &EditorLayout{Node: 1, First: &EditorLayout{Group: "editor:1"}, Second: &EditorLayout{Group: "editor:2"}}
		result := reduce(t, state, layout, RemoveEmptyEditorGroups([]string{"editor:1", "editor:2"}))
		if !slices.Equal(result.Removed, []string{"editor:2"}) || result.State.Group("editor:3") == nil {
			t.Fatalf("result = %+v, want only editor:2 removed", result)
		}
		if !slices.Equal(leafGroups(result.Layout), []string{"editor:1"}) {
			t.Fatalf("layout = %+v, want editor:1 alone", result.Layout)
		}
	})
}

func TestEditorDropTargets(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	state := EditorWorkbench{Groups: []EditorGroup{
		{ID: "tool", Members: []string{"terminal:1", "terminal:2"}},
		{ID: "editor:1", Members: []string{"document:1"}},
	}}
	layout := &EditorLayout{Group: "editor:1"}
	query := func(member string, dockable bool) EditorDropRules {
		t.Helper()
		rules, err := client.EditorDropTargets(ctx, EditorDropQuery{State: state, Layout: layout, Member: member, Docked: []string{"tool"}, Dockable: dockable})
		if err != nil {
			t.Fatalf("EditorDropTargets() error: %v", err)
		}
		return rules
	}
	terminal := query("terminal:1", true)
	if got := terminal.For("tool"); got != (EditorPlaceRules{Join: true}) {
		t.Errorf("terminal over tool = %+v, want join only", got)
	}
	if got := terminal.For("editor:1"); got != (EditorPlaceRules{Join: true, Split: true, Append: true}) {
		t.Errorf("terminal over editor:1 = %+v, want every place", got)
	}
	file := query("document:1", false)
	if got := file.For("tool"); got != (EditorPlaceRules{}) {
		t.Errorf("file over tool = %+v, want nothing", got)
	}
	if got := file.For("editor:1"); got != (EditorPlaceRules{}) {
		t.Errorf("only tab over its group = %+v, want nothing", got)
	}
	if file.Empty || terminal.For("missing") != (EditorPlaceRules{}) {
		t.Errorf("empty = %v, unknown group = %+v; want false and nothing", file.Empty, terminal.For("missing"))
	}
	var none *EditorDropRules
	if none.For("tool") != (EditorPlaceRules{}) {
		t.Error("nil rules accepted a place")
	}
}

func TestEditorLayoutEncoding(t *testing.T) {
	layout := &EditorLayout{Node: 2, Row: true, First: &EditorLayout{Group: "a"}, Second: &EditorLayout{Group: "b"}}
	got, err := json.Marshal(layout)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"node":2,"row":true,"first":{"group":"a"},"second":{"group":"b"}}`; string(got) != want {
		t.Errorf("layout = %s, want %s", got, want)
	}
	var back EditorLayout
	if err := json.Unmarshal(got, &back); err != nil || !slices.Equal(leafGroups(&back), []string{"a", "b"}) || back.Node != 2 || !back.Row {
		t.Errorf("decoded %+v, %v; want the same layout", back, err)
	}
	if err := json.Unmarshal([]byte(`{"node":1,"first":{"group":"a"}}`), &back); err == nil {
		t.Error("a split with one child decoded")
	}
	if _, err := json.Marshal(EditorLayout{Node: 1}); err == nil {
		t.Error("a split with no children encoded")
	}
	if _, err := json.Marshal(EditorDropPlace{}); err == nil {
		t.Error("zero EditorDropPlace encoded")
	}
	cases := []struct {
		action EditorAction
		want   string
	}{
		{OpenEditorTab("m", "", "g"), `{"kind":"openTab","member":"m","newGroup":"g"}`},
		{DropEditorTab(EditorDrop{Member: "m", Target: EmptyEditorArea(), NewGroup: "g"}), `{"kind":"dropTab","member":"m","target":{"kind":"empty"},"docked":[],"dockable":false,"newGroup":"g"}`},
		{DropEditorTab(EditorDrop{Member: "m", Target: SplitEditorGroup("a", EditorEdgeTop), Docked: []string{"t"}, NewGroup: "g", NewNode: 3}), `{"kind":"dropTab","member":"m","target":{"kind":"split","group":"a","edge":"top"},"docked":["t"],"dockable":false,"newGroup":"g","newNode":3}`},
		{RemoveEmptyEditorGroups(nil), `{"kind":"removeEmptyGroups","groups":[]}`},
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
}
