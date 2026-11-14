package core

import (
	"context"
	"encoding/json"
	"errors"
)

// EditorLayout is the shape of the tree that divides the editor area among its tab groups: a
// leaf shows Group, and a split lays First and Second side by side (Row) or one over the other.
// Node is the host's number for a split, unique in the tree; the host keeps what its widgets
// need for each split, such as the splitter's ratio, under that number.
type EditorLayout struct {
	Group         string
	Node          int
	Row           bool
	First, Second *EditorLayout
}

// UnmarshalJSON decodes a leaf {group} or a split {node, row, first, second}.
func (l *EditorLayout) UnmarshalJSON(data []byte) error {
	var wire struct {
		Group  string        `json:"group"`
		Node   int           `json:"node"`
		Row    bool          `json:"row"`
		First  *EditorLayout `json:"first"`
		Second *EditorLayout `json:"second"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire.Group == "" && (wire.First == nil || wire.Second == nil) {
		return errors.New("core: an editor layout split lacks a child")
	}
	*l = EditorLayout{Group: wire.Group, Node: wire.Node, Row: wire.Row, First: wire.First, Second: wire.Second}
	return nil
}

// MarshalJSON encodes a leaf as {group} and a split as {node, row, first, second}; Core
// rejects any other field.
func (l EditorLayout) MarshalJSON() ([]byte, error) {
	if l.Group != "" {
		return json.Marshal(struct {
			Group string `json:"group"`
		}{l.Group})
	}
	if l.First == nil || l.Second == nil {
		return nil, errors.New("core: an editor layout split lacks a child")
	}
	return json.Marshal(struct {
		Node   int           `json:"node"`
		Row    bool          `json:"row"`
		First  *EditorLayout `json:"first"`
		Second *EditorLayout `json:"second"`
	}{l.Node, l.Row, l.First, l.Second})
}

// EditorEdge is a side of a group, where a dropped tab splits it.
type EditorEdge string

// The sides of a group.
const (
	EditorEdgeLeft   EditorEdge = "left"
	EditorEdgeRight  EditorEdge = "right"
	EditorEdgeTop    EditorEdge = "top"
	EditorEdgeBottom EditorEdge = "bottom"
)

// EditorDropPlace is where a dragged tab is released. Build it with JoinEditorGroup,
// SplitEditorGroup or EmptyEditorArea.
type EditorDropPlace struct {
	kind  string
	group string
	index int
	edge  EditorEdge
}

// JoinEditorGroup puts the tab into group as its tab at index, counted among the group's tabs
// without the dragged one.
func JoinEditorGroup(group string, index int) EditorDropPlace {
	return EditorDropPlace{kind: "join", group: group, index: index}
}

// SplitEditorGroup puts the tab into a new group on side edge of group.
func SplitEditorGroup(group string, edge EditorEdge) EditorDropPlace {
	return EditorDropPlace{kind: "split", group: group, edge: edge}
}

// EmptyEditorArea puts the tab into the first group of an editor area that has none.
func EmptyEditorArea() EditorDropPlace { return EditorDropPlace{kind: "empty"} }

// MarshalJSON encodes the place as the exact object of its kind.
func (p EditorDropPlace) MarshalJSON() ([]byte, error) {
	switch p.kind {
	case "join":
		return json.Marshal(struct {
			Kind  string `json:"kind"`
			Group string `json:"group"`
			Index int    `json:"index"`
		}{p.kind, p.group, p.index})
	case "split":
		return json.Marshal(struct {
			Kind  string     `json:"kind"`
			Group string     `json:"group"`
			Edge  EditorEdge `json:"edge"`
		}{p.kind, p.group, p.edge})
	case "empty":
		return json.Marshal(struct {
			Kind string `json:"kind"`
		}{p.kind})
	}
	return nil, errors.New("core: zero EditorDropPlace; build one with JoinEditorGroup, SplitEditorGroup or EmptyEditorArea")
}

// EditorDrop is the release of a dragged tab.
type EditorDrop struct {
	Member string
	Target EditorDropPlace
	// Docked are the groups docked in a tool window: never split, kept when their last tab
	// leaves, and joined only by a Dockable tab.
	Docked   []string
	Dockable bool
	// NewGroup and NewNode are the group ID and split number the host offers for a group the
	// drop makes; the result's Group says whether it was made.
	NewGroup string
	NewNode  int
}

// OpenEditorTab opens member and shows it: in preferred while the layout shows it, else in the
// first group of the layout, else in group newGroup, made as the whole layout.
func OpenEditorTab(member, preferred, newGroup string) EditorAction {
	return EditorAction{kind: editorOpenTab, member: member, group: preferred, drop: EditorDrop{NewGroup: newGroup}}
}

// DropEditorTab releases a dragged tab on a place EditorDropTargets offered. A place that no
// longer fits the groups is rejected (EditorDropStale), never turned into a different move.
func DropEditorTab(drop EditorDrop) EditorAction {
	return EditorAction{kind: editorDropTab, drop: drop}
}

// RemoveEmptyEditorGroups removes the named groups that have no tab, and their leaves.
func RemoveEmptyEditorGroups(groups []string) EditorAction {
	return EditorAction{kind: editorRemoveEmpty, unplaced: groups}
}

// The rejections of DropEditorTab.
const (
	// EditorDropStale is a drop whose member or place no longer fits the groups, as when a tab
	// closed or a group went away while the tab was dragged.
	EditorDropStale = "editor.groupLayout.stale"
	// EditorDropRefused is a drop on a place the drop rules refuse.
	EditorDropRefused = "editor.groupLayout.refused"
)

type editorOpenTabWire struct {
	Kind           editorKind `json:"kind"`
	Member         string     `json:"member"`
	PreferredGroup *string    `json:"preferredGroup,omitempty"`
	NewGroup       string     `json:"newGroup"`
}

type editorRemoveEmptyWire struct {
	Kind   editorKind `json:"kind"`
	Groups []string   `json:"groups"`
}

func (d EditorDrop) marshal() ([]byte, error) {
	wire := struct {
		Kind     editorKind      `json:"kind"`
		Member   string          `json:"member"`
		Target   EditorDropPlace `json:"target"`
		Docked   []string        `json:"docked"`
		Dockable bool            `json:"dockable"`
		NewGroup *string         `json:"newGroup,omitempty"`
		NewNode  *int            `json:"newNode,omitempty"`
	}{Kind: editorDropTab, Member: d.Member, Target: d.Target, Docked: nonNil(d.Docked), Dockable: d.Dockable, NewGroup: optional(d.NewGroup)}
	if d.NewNode > 0 {
		wire.NewNode = &d.NewNode
	}
	return json.Marshal(wire)
}

// EditorLayoutResult is the outcome of one editor.groupLayout.reduce.
type EditorLayoutResult struct {
	State EditorWorkbench `json:"state"`
	// Layout is nil when the editor area shows no group.
	Layout *EditorLayout `json:"layout"`
	// Removed is the groups that left the state, in their previous order.
	Removed []string `json:"removedGroupIds"`
	// Group is the group the tab is in after OpenEditorTab or DropEditorTab.
	Group string `json:"group"`
	// Rejection says why a drop did not apply; State and Layout are then as sent.
	Rejection string `json:"rejection"`
}

// ReduceEditorLayout applies action to the groups and the layout together
// (editor.groupLayout.reduce): any workbench action, after which a leaf whose group left the
// state leaves the layout and its sibling takes the room, or OpenEditorTab, DropEditorTab and
// RemoveEmptyEditorGroups. The layout first loses the leaves of groups state does not have.
//
// The call only computes over its arguments and is fast enough for an event handler.
func (c *Client) ReduceEditorLayout(ctx context.Context, state EditorWorkbench, layout *EditorLayout, action EditorAction) (EditorLayoutResult, error) {
	payload := struct {
		State  EditorWorkbench `json:"state"`
		Layout *EditorLayout   `json:"layout"`
		Action EditorAction    `json:"action"`
	}{state, layout, action}
	var result EditorLayoutResult
	if err := c.Execute(ctx, "editor.groupLayout.reduce", payload, &result); err != nil {
		return EditorLayoutResult{}, err
	}
	result.State.Groups = nonNil(result.State.Groups)
	for i := range result.State.Groups {
		g := &result.State.Groups[i]
		g.Members, g.MRU, g.Pinned = nonNil(g.Members), nonNil(g.MRU), nonNil(g.Pinned)
	}
	result.Removed = nonNil(result.Removed)
	return result, nil
}

// EditorDropQuery is a drag that starts: the groups, the layout and the dragged tab.
type EditorDropQuery struct {
	State    EditorWorkbench
	Layout   *EditorLayout
	Member   string
	Docked   []string
	Dockable bool
}

// EditorPlaceRules says which places of one group accept the dragged tab.
type EditorPlaceRules struct {
	// Join is the strip of tabs: the tab joins at the place it is dropped.
	Join bool `json:"join"`
	// Split is the edges of the body: the tab splits the group on that side.
	Split bool `json:"split"`
	// Append is the middle of the body: the tab joins at the end.
	Append bool `json:"append"`
}

// EditorGroupDropRules is the rules of one group.
type EditorGroupDropRules struct {
	Group string `json:"group"`
	EditorPlaceRules
}

// EditorDropRules is where a dragged tab may land, for as long as the drag lasts.
type EditorDropRules struct {
	// Groups is every group of the state, in its order.
	Groups []EditorGroupDropRules `json:"groups"`
	// Empty says the editor area has no group and the tab may open its first one.
	Empty bool `json:"empty"`
}

// For is the rules of group; a group Core did not see accepts nothing.
func (r *EditorDropRules) For(group string) EditorPlaceRules {
	if r == nil {
		return EditorPlaceRules{}
	}
	for _, g := range r.Groups {
		if g.Group == group {
			return g.EditorPlaceRules
		}
	}
	return EditorPlaceRules{}
}

// EditorDropTargets has Core say, once per drag, which places of each group accept the
// dragged tab (editor.groupLayout.dropTargets). The host hit-tests against what it painted.
func (c *Client) EditorDropTargets(ctx context.Context, query EditorDropQuery) (EditorDropRules, error) {
	payload := struct {
		State    EditorWorkbench `json:"state"`
		Layout   *EditorLayout   `json:"layout"`
		Member   string          `json:"member"`
		Docked   []string        `json:"docked"`
		Dockable bool            `json:"dockable"`
	}{query.State, query.Layout, query.Member, nonNil(query.Docked), query.Dockable}
	var rules EditorDropRules
	if err := c.Execute(ctx, "editor.groupLayout.dropTargets", payload, &rules); err != nil {
		return EditorDropRules{}, err
	}
	return rules, nil
}
