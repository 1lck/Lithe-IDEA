// Package pluginview draws plugin views (API-13): the host controls, trees and canvas
// scenes that a plugin's view function returns for a tool window body or a settings
// region (settingRegions, API-19).
//
// Core checks every result and applies its patches (plugins.ui.applyResult) before
// the host sees it, so this package keeps no validator or patch engine of its own. It
// decodes the checked view, draws it with Viva each frame, and turns user input into
// view events. Hovering, pressing, focus, tooltips, tree expansion, scrolling,
// panning and zooming stay in the host and never reach the plugin.
//
// View state (text being typed, open tree items, a canvas's pan and zoom) lives in
// memory only. Nothing is written to disk, to the installed package or to the
// application bundle.
package pluginview

import (
	"encoding/json"
	"errors"
)

// Node is one view node of any type; Type selects which fields apply. Core checked
// the node against plugin-ui.schema.json and the README rules, so fields that belong
// to other types are absent.
type Node struct {
	Type     string `json:"type"`
	ID       string `json:"id,omitempty"`
	Children []Node `json:"children,omitempty"`
	Title    string `json:"title,omitempty"`
	Info     string `json:"info,omitempty"`
	Text     string `json:"text,omitempty"`
	Tone     string `json:"tone,omitempty"`
	Style    string `json:"style,omitempty"`
	// Width is a label's reserved character count, or a text field's "fill" or count.
	Width json.RawMessage `json:"width,omitempty"`
	Label string          `json:"label,omitempty"`
	// Value is a control's own value: a string, or a boolean for a toggle.
	Value       json.RawMessage `json:"value,omitempty"`
	Setting     string          `json:"setting,omitempty"`
	Placeholder string          `json:"placeholder,omitempty"`
	Mono        bool            `json:"mono,omitempty"`
	Enabled     *bool           `json:"enabled,omitempty"`
	Options     []Option        `json:"options,omitempty"`
	Icon        string          `json:"icon,omitempty"`
	Action      string          `json:"action,omitempty"`
	// Items are a keyValue's pairs or a tree's top-level items.
	Items   []Item     `json:"items,omitempty"`
	Columns []Column   `json:"columns,omitempty"`
	Rows    [][]string `json:"rows,omitempty"`
	Tool    string     `json:"tool,omitempty"`
	// Choose makes a tool row in a settings region also the tool's picker.
	Choose bool   `json:"choose,omitempty"`
	Cursor string `json:"cursor,omitempty"`
	// Height, ViewBox, Pan, Zoom, On and Nodes describe a canvas.
	Height  float64     `json:"height,omitempty"`
	ViewBox [4]float64  `json:"viewBox,omitempty"`
	Pan     bool        `json:"pan,omitempty"`
	Zoom    *[2]float64 `json:"zoom,omitempty"`
	On      []string    `json:"on,omitempty"`
	Nodes   []Shape     `json:"nodes,omitempty"`
}

// Option is one choice of a select or segmented control.
type Option struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// Item is a keyValue pair (Label, Value, Tone) or a tree item (ID, Label, Icon,
// Detail, Expanded, Children).
type Item struct {
	ID          string `json:"id,omitempty"`
	Label       string `json:"label"`
	Value       string `json:"value,omitempty"`
	Tone        string `json:"tone,omitempty"`
	Icon        string `json:"icon,omitempty"`
	Detail      string `json:"detail,omitempty"`
	Expanded    bool   `json:"expanded,omitempty"`
	HasChildren bool   `json:"hasChildren,omitempty"`
	Children    []Item `json:"children,omitempty"`
}

// Column is one column of a table.
type Column struct {
	Title string `json:"title"`
	Align string `json:"align,omitempty"`
}

// Shape is one canvas node of any type; Type selects which fields apply.
type Shape struct {
	Type   string  `json:"type"`
	ID     string  `json:"id,omitempty"`
	X      float64 `json:"x,omitempty"`
	Y      float64 `json:"y,omitempty"`
	W      float64 `json:"w,omitempty"`
	H      float64 `json:"h,omitempty"`
	Radius float64 `json:"radius,omitempty"`
	Fill   *Color  `json:"fill,omitempty"`
	Stroke *Color  `json:"stroke,omitempty"`
	// Width is the stroke width in view-box units, 1 when absent.
	Width   *float64  `json:"width,omitempty"`
	Dash    []float64 `json:"dash,omitempty"`
	Shadow  int       `json:"shadow,omitempty"`
	Opacity *float64  `json:"opacity,omitempty"`
	// D, Bounds, Cap and Rule describe a path.
	D      string      `json:"d,omitempty"`
	Bounds *[4]float64 `json:"bounds,omitempty"`
	Cap    string      `json:"cap,omitempty"`
	Rule   string      `json:"rule,omitempty"`
	// Text, Runs, Style, Align, Color and MaxWidth describe text.
	Text     string  `json:"text,omitempty"`
	Runs     []Run   `json:"runs,omitempty"`
	Style    string  `json:"style,omitempty"`
	Align    string  `json:"align,omitempty"`
	Color    *Color  `json:"color,omitempty"`
	MaxWidth float64 `json:"maxWidth,omitempty"`
	// Src is an image's package-relative PNG path.
	Src string `json:"src,omitempty"`
	// Scale, Clip, Children, On, Label, Tooltip, States, Selected and Hidden describe a group.
	Scale    *float64 `json:"scale,omitempty"`
	Clip     bool     `json:"clip,omitempty"`
	Children []Shape  `json:"children,omitempty"`
	On       []string `json:"on,omitempty"`
	Label    string   `json:"label,omitempty"`
	Tooltip  string   `json:"tooltip,omitempty"`
	States   *States  `json:"states,omitempty"`
	Selected bool     `json:"selected,omitempty"`
	Hidden   bool     `json:"hidden,omitempty"`

	// geometry is the parsed path, made on first draw and kept with the decoded view.
	geometry *pathGeometry
	// fullText joins colored runs only when first needed by an overflow tooltip.
	// Shapes belong to an immutable decoded view, so later paints reuse it.
	fullText string
}

// Run is one differently colored part of a text node.
type Run struct {
	Text  string `json:"text"`
	Color *Color `json:"color,omitempty"`
}

// States are what the host draws while a clickable group is hovered, pressed or selected.
type States struct {
	Hover    *State `json:"hover,omitempty"`
	Pressed  *State `json:"pressed,omitempty"`
	Selected *State `json:"selected,omitempty"`
}

// State paints the group's w × h area behind its children (Fill, Stroke, Width,
// Shadow) and changes the whole group (Scale, Opacity).
type State struct {
	Fill    *Color   `json:"fill,omitempty"`
	Stroke  *Color   `json:"stroke,omitempty"`
	Width   *float64 `json:"width,omitempty"`
	Shadow  int      `json:"shadow,omitempty"`
	Scale   *float64 `json:"scale,omitempty"`
	Opacity *float64 `json:"opacity,omitempty"`
}

// Color is a plain color (#RRGGBB, #RRGGBBAA or a $token), a light and dark pair, or
// a linear gradient of stops. Angle follows CSS: 0 runs upward, 90 to the right, and
// an absent angle is 180, top to bottom.
type Color struct {
	Plain string
	Light string
	Dark  string
	Stops []Stop
	Angle float64
}

// Stop is one gradient stop: a plain color at an offset from 0 to 1.
type Stop struct {
	At    float64
	Color string
}

// UnmarshalJSON reads the three color forms of plugin-ui.schema.json#/$defs/color.
func (c *Color) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		return json.Unmarshal(data, &c.Plain)
	}
	var object struct {
		Light  string               `json:"light"`
		Dark   string               `json:"dark"`
		Linear [][2]json.RawMessage `json:"linear"`
		Angle  *float64             `json:"angle"`
	}
	if err := json.Unmarshal(data, &object); err != nil {
		return err
	}
	c.Light, c.Dark, c.Angle = object.Light, object.Dark, 180
	if object.Angle != nil {
		c.Angle = *object.Angle
	}
	for _, pair := range object.Linear {
		var stop Stop
		if err := json.Unmarshal(pair[0], &stop.At); err != nil {
			return err
		}
		if err := json.Unmarshal(pair[1], &stop.Color); err != nil {
			return err
		}
		c.Stops = append(c.Stops, stop)
	}
	return nil
}

// Decode reads a view Core returned. A view that is not an array of nodes is an
// error; Core never returns one, so it means the host and Core disagree.
func Decode(view json.RawMessage) ([]Node, error) {
	if len(view) == 0 {
		return nil, errors.New("pluginview: empty view")
	}
	var nodes []Node
	if err := json.Unmarshal(view, &nodes); err != nil {
		return nil, err
	}
	return nodes, nil
}

// enabled reports whether a control accepts input; a control is enabled unless it says otherwise.
func (n *Node) enabled() bool {
	return n.Enabled == nil || *n.Enabled
}

// stringValue is a control's own string value, empty when it has none.
func (n *Node) stringValue() string {
	var value string
	if len(n.Value) > 0 {
		_ = json.Unmarshal(n.Value, &value)
	}
	return value
}

// boolValue is a toggle's own value, false when it has none.
func (n *Node) boolValue() bool {
	var value bool
	if len(n.Value) > 0 {
		_ = json.Unmarshal(n.Value, &value)
	}
	return value
}

// characters is a label's or text field's reserved character count, 0 for none.
// fill reports a text field that takes the row's free width.
func (n *Node) characters() (count int, fill bool) {
	if len(n.Width) == 0 {
		return 0, false
	}
	if string(n.Width) == `"fill"` {
		return 0, true
	}
	_ = json.Unmarshal(n.Width, &count)
	return count, false
}

// clickable reports whether a group is a control.
func (s *Shape) clickable() bool {
	return s.Type == "group" && len(s.On) > 0
}

// opacity is the shape's opacity, 1 when absent.
func (s *Shape) opacity() float32 {
	if s.Opacity == nil {
		return 1
	}
	return float32(*s.Opacity)
}

// strokeWidth is the shape's stroke width in view-box units, 1 when absent.
func (s *Shape) strokeWidth() float64 {
	if s.Width == nil {
		return 1
	}
	return *s.Width
}

// scale is a group's scale, 1 when absent.
func (s *Shape) scale() float64 {
	if s.Scale == nil {
		return 1
	}
	return *s.Scale
}
