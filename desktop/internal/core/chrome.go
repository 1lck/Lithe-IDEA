package core

import (
	"context"
	"encoding/json"
	"errors"
)

// Zone is one place a rearrangeable workbench button can sit in. The values are the names the
// kernel uses.
//
// The six tool stripe zones are the tool window anchors of the IDEA new UI, three on each
// stripe. The names are easy to mix up: ZoneLeftBottom and ZoneBottomLeft are different zones,
// and so are ZoneRightBottom and ZoneBottomRight. The first pair opens in the lower half of the
// left or right column, the second in the left or right half of the bottom area.
type Zone string

const (
	// ZoneLeftTop is the upper group of the left tool stripe; its tool window opens in the left
	// column, in the top half when ZoneLeftBottom also has one open.
	ZoneLeftTop Zone = "leftTop"
	// ZoneLeftBottom is the group of the left tool stripe directly under ZoneLeftTop; its tool
	// window opens in the lower half of the left column.
	ZoneLeftBottom Zone = "leftBottom"
	// ZoneBottomLeft is the group packed at the bottom of the left tool stripe; its tool window
	// opens in the left half of the bottom area.
	ZoneBottomLeft Zone = "bottomLeft"
	// ZoneRightTop is the upper group of the right tool stripe; its tool window opens in the
	// right column, in the top half when ZoneRightBottom also has one open.
	ZoneRightTop Zone = "rightTop"
	// ZoneRightBottom is the group of the right tool stripe directly under ZoneRightTop; its tool
	// window opens in the lower half of the right column.
	ZoneRightBottom Zone = "rightBottom"
	// ZoneBottomRight is the group packed at the bottom of the right tool stripe; its tool window
	// opens in the right half of the bottom area.
	ZoneBottomRight Zone = "bottomRight"
	// ZoneTitleTrailing is the trailing end of the title bar.
	ZoneTitleTrailing Zone = "titleTrailing"
	// ZoneStatusTrailing is the trailing end of the status bar.
	ZoneStatusTrailing Zone = "statusTrailing"
)

// ChromeItem is one button the host is able to show. The order of the catalog is the default
// order inside each zone.
type ChromeItem struct {
	// ID is the stable host identifier, persisted in placements. It must be unique and not
	// empty.
	ID string `json:"id"`
	// DefaultZone is the zone of the default layout. Its surface (the tool stripes, the title
	// bar or the status bar) is the only surface the item may ever sit in.
	DefaultZone Zone `json:"defaultZone"`
	// Panel reports that the button opens a tool panel in its zone's panel slot. Only the six
	// tool stripe zones can host a panel.
	Panel bool `json:"panel,omitempty"`
	// OpenByDefault reports that the panel is open in the default layout. It requires Panel.
	OpenByDefault bool `json:"openByDefault,omitempty"`
}

// Placement is the zone of one item. The order of the placements that share a zone is the
// display order inside that zone.
type Placement struct {
	// ID is the catalog identifier of the item.
	ID string `json:"id"`
	// Zone is the zone the item sits in.
	Zone Zone `json:"zone"`
}

// ChromeLayout is the persisted state of the rearrangeable workbench chrome. The zero value is
// an empty layout and is a valid input: the kernel completes it from the catalog.
//
// A layout returned by ReduceChromeLayout lists every catalog item exactly once, zone by zone in
// the order of the Zone constants, Open names at most one panel item per zone, also in zone
// order, and Hidden lists the hidden tool stripe items in the order of Placements.
type ChromeLayout struct {
	// Placements is every item with its zone. A hidden item keeps its placement, so showing it
	// again puts it back where it was.
	Placements []Placement `json:"placements"`
	// Open lists the panel items whose panel is shown. A hidden item's panel can be open: a
	// shortcut or command opens it without showing the button.
	Open []string `json:"open"`
	// Hidden lists the tool stripe items whose button the user hid from the stripe.
	Hidden []string `json:"hidden"`
}

// MarshalJSON encodes the layout with empty lists as [] instead of null, because the kernel
// rejects null for them.
func (l ChromeLayout) MarshalJSON() ([]byte, error) {
	type wire struct {
		Placements []Placement `json:"placements"`
		Open       []string    `json:"open"`
		Hidden     []string    `json:"hidden"`
	}
	return json.Marshal(wire{Placements: nonNil(l.Placements), Open: nonNil(l.Open), Hidden: nonNil(l.Hidden)})
}

// chromeKind names the variants of a ChromeAction. The values are the "kind" tags of the Rust
// chrome layout Action enum.
type chromeKind string

const (
	chromeNormalize chromeKind = "normalize"
	chromeReset     chromeKind = "reset"
	chromeMove      chromeKind = "move"
	chromeToggle    chromeKind = "toggle"
	chromeSetOpen   chromeKind = "setOpen"
	chromeSetHidden chromeKind = "setHidden"
)

// ChromeAction is one transition of the chrome layout. Build it with NormalizeChrome,
// ResetChrome, MoveChrome, ToggleChrome, SetChromeOpen or SetChromeHidden; the zero value is not
// a valid action and cannot be encoded.
type ChromeAction struct {
	kind   chromeKind
	id     string
	zone   Zone
	before string
	open   bool
	hidden bool
}

// NormalizeChrome repairs a saved layout against the catalog without changing anything else:
// it drops placements of items the catalog no longer lists and puts new items at the end of
// their default zone.
func NormalizeChrome() ChromeAction {
	return ChromeAction{kind: chromeNormalize}
}

// ResetChrome replaces the layout with the default layout of the catalog, which shows every
// item.
func ResetChrome() ChromeAction {
	return ChromeAction{kind: chromeReset}
}

// MoveChrome moves the item id into zone, in front of the item before when that item sits in
// zone and at the end of the zone otherwise. An empty before always means the end. The zone
// must belong to the item's own surface; moving a stripe button into the status bar fails with
// CodeInvalidRequest.
func MoveChrome(id string, zone Zone, before string) ChromeAction {
	return ChromeAction{kind: chromeMove, id: id, zone: zone, before: before}
}

// ToggleChrome opens the panel of the item id when it is closed and closes it when it is open.
// Opening a panel closes the other open panel of its zone.
func ToggleChrome(id string) ChromeAction {
	return ChromeAction{kind: chromeToggle, id: id}
}

// SetChromeOpen opens or closes the panel of the item id.
func SetChromeOpen(id string, open bool) ChromeAction {
	return ChromeAction{kind: chromeSetOpen, id: id, open: open}
}

// SetChromeHidden hides or shows the tool stripe button of the item id. Hiding closes the item's
// panel; showing leaves the panel as it is. A hidden item keeps its zone and position. Only tool
// stripe items can be hidden; a title or status bar item fails with CodeInvalidRequest.
func SetChromeHidden(id string, hidden bool) ChromeAction {
	return ChromeAction{kind: chromeSetHidden, id: id, hidden: hidden}
}

// chromeKindWire, chromeMoveWire, chromeIDWire, chromeSetOpenWire and chromeSetHiddenWire are
// the exact JSON shapes of the action variants. The kernel rejects unknown fields, so each variant encodes only its
// own fields.
type chromeKindWire struct {
	Kind chromeKind `json:"kind"`
}

type chromeMoveWire struct {
	Kind   chromeKind `json:"kind"`
	ID     string     `json:"id"`
	Zone   Zone       `json:"zone"`
	Before string     `json:"before,omitempty"`
}

type chromeIDWire struct {
	Kind chromeKind `json:"kind"`
	ID   string     `json:"id"`
}

type chromeSetOpenWire struct {
	Kind chromeKind `json:"kind"`
	ID   string     `json:"id"`
	Open bool       `json:"open"`
}

type chromeSetHiddenWire struct {
	Kind   chromeKind `json:"kind"`
	ID     string     `json:"id"`
	Hidden bool       `json:"hidden"`
}

// MarshalJSON encodes the action as the exact object of its variant.
func (a ChromeAction) MarshalJSON() ([]byte, error) {
	switch a.kind {
	case chromeNormalize, chromeReset:
		return json.Marshal(chromeKindWire{Kind: a.kind})
	case chromeMove:
		return json.Marshal(chromeMoveWire{Kind: a.kind, ID: a.id, Zone: a.zone, Before: a.before})
	case chromeToggle:
		return json.Marshal(chromeIDWire{Kind: a.kind, ID: a.id})
	case chromeSetOpen:
		return json.Marshal(chromeSetOpenWire{Kind: a.kind, ID: a.id, Open: a.open})
	case chromeSetHidden:
		return json.Marshal(chromeSetHiddenWire{Kind: a.kind, ID: a.id, Hidden: a.hidden})
	}
	return nil, errors.New("core: zero ChromeAction; build one with NormalizeChrome, ResetChrome, MoveChrome, ToggleChrome, SetChromeOpen or SetChromeHidden")
}

// chromeLayoutRequest is the payload of workbench.chromeLayout.reduce. The kernel rejects
// unknown fields.
type chromeLayoutRequest struct {
	Catalog []ChromeItem `json:"catalog"`
	State   ChromeLayout `json:"state"`
	Action  ChromeAction `json:"action"`
}

// chromeLayoutResponse is the data of workbench.chromeLayout.reduce.
type chromeLayoutResponse struct {
	State   ChromeLayout `json:"state"`
	Changed bool         `json:"changed"`
}

// ReduceChromeLayout applies action to the saved layout state, after repairing state against
// catalog, and returns the complete resulting layout together with whether it differs from the
// state that was sent; when it does, the host should persist it. The host keeps only what exists
// while a gesture runs (pointer, drag ghost, insertion marker) and sends one action when the
// gesture ends.
//
// The kernel never invents items: it drops placements of items the catalog does not list and
// puts catalog items the state does not mention at the end of their default zone. Each stripe
// zone owns one panel slot, so opening a panel closes the other open panel of its zone, and
// moving an open panel takes its open state into the target zone.
//
// The kernel answers CodeInvalidRequest for a malformed catalog (an empty or repeated id, a
// panel outside the tool stripes, a default-open item that is not a panel) and for an action
// that names an unknown item, moves an item to another surface, opens an item that is not a
// panel or hides an item outside the tool stripes.
//
// The call only computes over its arguments and is fast enough for an event handler.
func (c *Client) ReduceChromeLayout(ctx context.Context, catalog []ChromeItem, state ChromeLayout, action ChromeAction) (ChromeLayout, bool, error) {
	request := chromeLayoutRequest{
		Catalog: nonNil(catalog),
		State:   state,
		Action:  action,
	}
	var response chromeLayoutResponse
	if err := c.Execute(ctx, "workbench.chromeLayout.reduce", request, &response); err != nil {
		return ChromeLayout{}, false, err
	}
	return ChromeLayout{
		Placements: nonNil(response.State.Placements),
		Open:       nonNil(response.State.Open),
		Hidden:     nonNil(response.State.Hidden),
	}, response.Changed, nil
}
