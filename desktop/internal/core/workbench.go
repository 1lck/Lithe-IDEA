package core

import (
	"encoding/json"
	"errors"
	"slices"
)

// EditorGroup is one tab group: the members it lists in tab order, the one it shows, and the
// order they were last used in. A member is any stable string the host chooses; the desktop
// client uses "terminal:<id>".
type EditorGroup struct {
	// ID is the group's stable identifier.
	ID string `json:"id"`
	// Members is the group's tabs, in order.
	Members []string `json:"members"`
	// Selected is the member the group shows; empty when it shows none.
	Selected string `json:"selected,omitempty"`
	// MRU lists the members from the most recently used.
	MRU []string `json:"mru"`
	// Pinned lists the pinned members (PinEditor).
	Pinned []string `json:"pinned"`
	// Preview is the member shown as a preview tab; empty when there is none.
	Preview string `json:"preview,omitempty"`
}

// EditorWorkbench is the state of a set of tab groups. The zero value has no groups and is a
// valid input.
type EditorWorkbench struct {
	// Groups lists the groups in the order the host lays them out by.
	Groups []EditorGroup `json:"groups"`
	// FocusedGroup is the group new members join. Empty means the host keeps no focus, and
	// then the kernel keeps none either.
	FocusedGroup string `json:"focusedGroup,omitempty"`
}

// MarshalJSON encodes the state with empty lists as [] instead of null.
func (w EditorWorkbench) MarshalJSON() ([]byte, error) {
	type wire struct {
		Groups       []EditorGroup `json:"groups"`
		FocusedGroup string        `json:"focusedGroup,omitempty"`
	}
	return json.Marshal(wire{Groups: nonNil(w.Groups), FocusedGroup: w.FocusedGroup})
}

// MarshalJSON encodes the group with empty lists as [] instead of null.
func (g EditorGroup) MarshalJSON() ([]byte, error) {
	type wire struct {
		ID       string   `json:"id"`
		Members  []string `json:"members"`
		Selected string   `json:"selected,omitempty"`
		MRU      []string `json:"mru"`
		Pinned   []string `json:"pinned"`
		Preview  string   `json:"preview,omitempty"`
	}
	return json.Marshal(wire{
		ID: g.ID, Members: nonNil(g.Members), Selected: g.Selected,
		MRU: nonNil(g.MRU), Pinned: nonNil(g.Pinned), Preview: g.Preview,
	})
}

// Group is the group with id, and nil when the state has none.
func (w *EditorWorkbench) Group(id string) *EditorGroup {
	for i := range w.Groups {
		if w.Groups[i].ID == id {
			return &w.Groups[i]
		}
	}
	return nil
}

// GroupOf is the group that lists member, and nil when none does.
func (w *EditorWorkbench) GroupOf(member string) *EditorGroup {
	for i := range w.Groups {
		for _, m := range w.Groups[i].Members {
			if m == member {
				return &w.Groups[i]
			}
		}
	}
	return nil
}

// EmptyGroups says what an action does with a group it leaves empty. The values are the
// kernel's names.
type EmptyGroups string

const (
	// KeepEmptyGroups keeps the group, as a tool window keeps its strip with no tabs.
	KeepEmptyGroups EmptyGroups = "keep"
	// RemoveEmptyGroups removes the group, as an editor split closes with its last tab.
	RemoveEmptyGroups EmptyGroups = "remove"
	// RemoveEmptyGroupsKeepingFirst removes the group unless it is the first one.
	RemoveEmptyGroupsKeepingFirst EmptyGroups = "removeKeepingFirst"
)

// SelectionFallback says which member a group shows after its selected one leaves.
type SelectionFallback string

const (
	// SelectAdjacent shows the member that slides into the vacated place, or the new last.
	SelectAdjacent SelectionFallback = "adjacent"
	// SelectFirst shows the first remaining member.
	SelectFirst SelectionFallback = "first"
)

// editorKind names the variants of an EditorAction. The values are the "kind" tags of the Rust
// workbench state Action enum.
type editorKind string

const (
	editorNormalize editorKind = "normalize"
	editorOpen      editorKind = "open"
	editorClose     editorKind = "close"
	editorActivate  editorKind = "activate"
	editorMove      editorKind = "move"
	editorReorder   editorKind = "reorder"
	editorMerge     editorKind = "mergeGroup"
	editorPin       editorKind = "setPinned"
	editorPinAll    editorKind = "setPinnedEverywhere"
	// The transitions only editor.groupLayout.reduce has (editor_layout.go).
	editorOpenTab     editorKind = "openTab"
	editorDropTab     editorKind = "dropTab"
	editorRemoveEmpty editorKind = "removeEmptyGroups"
)

// EditorAction is one transition of an EditorWorkbench and its layout. Build it with
// NormalizeEditor, OpenEditor, CloseEditor, ActivateEditor, MoveEditor, ReorderEditor,
// MergeEditorGroups, PinEditor, PinEditorEverywhere, OpenEditorTab, DropEditorTab or
// RemoveEmptyEditorGroups; the zero value is not a valid action and cannot be encoded.
type EditorAction struct {
	kind     editorKind
	group    string
	member   string
	activate bool
	empty    EmptyGroups
	fallback SelectionFallback
	// unplaced is the members NormalizeEditor places, and the groups RemoveEmptyEditorGroups
	// names.
	unplaced []string
	move     EditorMove
	drop     EditorDrop
	from, to int
}

// NormalizeEditor repairs every group (a selection that is not a member, a member listed
// twice) and lets the focused group take the unplaced members no group lists yet.
func NormalizeEditor(empty EmptyGroups, unplaced []string) EditorAction {
	return EditorAction{kind: editorNormalize, empty: empty, unplaced: unplaced}
}

// OpenEditor adds member to the end of group when the group lacks it; with activate, the group
// then shows it.
func OpenEditor(group, member string, activate bool) EditorAction {
	return EditorAction{kind: editorOpen, group: group, member: member, activate: activate}
}

// CloseEditor removes member from group. empty decides whether a group left empty stays, and
// fallback which member the group shows when member was the one it showed.
func CloseEditor(group, member string, empty EmptyGroups, fallback SelectionFallback) EditorAction {
	return EditorAction{kind: editorClose, group: group, member: member, empty: empty, fallback: fallback}
}

// ActivateEditor makes group show member. An empty member only repairs the selection.
func ActivateEditor(group, member string) EditorAction {
	return EditorAction{kind: editorActivate, group: group, member: member}
}

// EditorMove is a move of one member between two groups, or inside one.
type EditorMove struct {
	Member string
	// From is the group that loses the member and To the one that gains it; they may be the
	// same group, and then the member only changes place.
	From, To string
	// Before and After place the member next to a member of To; both empty put it at the end.
	Before, After string
	// Activate makes To show the member.
	Activate bool
	// Empty decides whether From stays when the move leaves it empty, and Fallback what From
	// shows when the member was its selection.
	Empty    EmptyGroups
	Fallback SelectionFallback
}

// MoveEditor moves a member from one group into another.
func MoveEditor(move EditorMove) EditorAction {
	return EditorAction{kind: editorMove, move: move}
}

// ReorderEditor moves the member at index from of group to index to. An index out of range
// changes nothing.
func ReorderEditor(group string, from, to int) EditorAction {
	return EditorAction{kind: editorReorder, group: group, from: from, to: to}
}

// MergeEditorGroups folds every member of from into into and removes from; with activate,
// into then shows what from showed.
func MergeEditorGroups(from, into string, activate bool) EditorAction {
	return EditorAction{kind: editorMerge, group: from, member: into, activate: activate}
}

// PinEditor pins or unpins member in group. Pinning clears a preview of the same member.
func PinEditor(group, member string, pinned bool) EditorAction {
	return EditorAction{kind: editorPin, group: group, member: member, activate: pinned}
}

// PinEditorEverywhere pins or unpins member in every group that lists it.
func PinEditorEverywhere(member string, pinned bool) EditorAction {
	return EditorAction{kind: editorPinAll, member: member, activate: pinned}
}

// IsPinned reports whether the group pins member.
func (g *EditorGroup) IsPinned(member string) bool {
	return g != nil && slices.Contains(g.Pinned, member)
}

// The exact JSON shapes of the action variants. The kernel rejects unknown fields, so each
// variant encodes only its own.
type editorNormalizeWire struct {
	Kind        editorKind  `json:"kind"`
	EmptyGroups EmptyGroups `json:"emptyGroups,omitempty"`
	Unplaced    []string    `json:"unplaced"`
}

type editorOpenWire struct {
	Kind     editorKind `json:"kind"`
	Group    string     `json:"group"`
	Member   string     `json:"member"`
	Activate bool       `json:"activate"`
}

type editorCloseWire struct {
	Kind              editorKind        `json:"kind"`
	Group             string            `json:"group"`
	Member            string            `json:"member"`
	EmptyGroups       EmptyGroups       `json:"emptyGroups,omitempty"`
	SelectionFallback SelectionFallback `json:"selectionFallback,omitempty"`
}

type editorActivateWire struct {
	Kind   editorKind `json:"kind"`
	Group  string     `json:"group"`
	Member *string    `json:"member"`
}

type editorMoveWire struct {
	Kind              editorKind        `json:"kind"`
	Member            string            `json:"member"`
	From              string            `json:"from"`
	To                string            `json:"to"`
	Before            *string           `json:"before,omitempty"`
	After             *string           `json:"after,omitempty"`
	Activate          bool              `json:"activate"`
	EmptyGroups       EmptyGroups       `json:"emptyGroups,omitempty"`
	SelectionFallback SelectionFallback `json:"selectionFallback,omitempty"`
}

type editorReorderWire struct {
	Kind      editorKind `json:"kind"`
	Group     string     `json:"group"`
	FromIndex int        `json:"fromIndex"`
	ToIndex   int        `json:"toIndex"`
}

type editorPinWire struct {
	Kind   editorKind `json:"kind"`
	Group  string     `json:"group,omitempty"`
	Member string     `json:"member"`
	Pinned bool       `json:"pinned"`
}

type editorMergeWire struct {
	Kind             editorKind `json:"kind"`
	From             string     `json:"from"`
	Into             string     `json:"into"`
	ActivateSelected bool       `json:"activateSelected"`
}

// optional is s as an optional JSON string: nil, which encodes as absent or null, when empty.
func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// MarshalJSON encodes the action as the exact object of its variant.
func (a EditorAction) MarshalJSON() ([]byte, error) {
	switch a.kind {
	case editorNormalize:
		return json.Marshal(editorNormalizeWire{Kind: a.kind, EmptyGroups: a.empty, Unplaced: nonNil(a.unplaced)})
	case editorOpen:
		return json.Marshal(editorOpenWire{Kind: a.kind, Group: a.group, Member: a.member, Activate: a.activate})
	case editorClose:
		return json.Marshal(editorCloseWire{Kind: a.kind, Group: a.group, Member: a.member, EmptyGroups: a.empty, SelectionFallback: a.fallback})
	case editorActivate:
		return json.Marshal(editorActivateWire{Kind: a.kind, Group: a.group, Member: optional(a.member)})
	case editorMove:
		m := a.move
		return json.Marshal(editorMoveWire{
			Kind: a.kind, Member: m.Member, From: m.From, To: m.To,
			Before: optional(m.Before), After: optional(m.After), Activate: m.Activate,
			EmptyGroups: m.Empty, SelectionFallback: m.Fallback,
		})
	case editorReorder:
		return json.Marshal(editorReorderWire{Kind: a.kind, Group: a.group, FromIndex: a.from, ToIndex: a.to})
	case editorPin, editorPinAll:
		return json.Marshal(editorPinWire{Kind: a.kind, Group: a.group, Member: a.member, Pinned: a.activate})
	case editorMerge:
		return json.Marshal(editorMergeWire{Kind: a.kind, From: a.group, Into: a.member, ActivateSelected: a.activate})
	case editorOpenTab:
		return json.Marshal(editorOpenTabWire{Kind: a.kind, Member: a.member, PreferredGroup: optional(a.group), NewGroup: a.drop.NewGroup})
	case editorDropTab:
		return a.drop.marshal()
	case editorRemoveEmpty:
		return json.Marshal(editorRemoveEmptyWire{Kind: a.kind, Groups: nonNil(a.unplaced)})
	}
	return nil, errors.New("core: zero EditorAction; build one with NormalizeEditor, OpenEditor, CloseEditor, ActivateEditor, MoveEditor, ReorderEditor, MergeEditorGroups, PinEditor, PinEditorEverywhere, OpenEditorTab, DropEditorTab or RemoveEmptyEditorGroups")
}
