package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// ToolWindow is one tool window a plugin declares under ui.toolWindows: a
// plain text window (`ui` 1) or a page of the plugin's package (`ui` 2).
type ToolWindow struct {
	PluginID string
	// PluginName is the plugin's display name, which the host's own text
	// about the window, such as a dialog title, names it by.
	PluginName string
	// Package is the installed package directory, read only.
	Package string
	// Manifest is the installed manifest, which Core validated at install
	// and validates again when a page of the window opens.
	Manifest json.RawMessage
	ID       string
	Title    string
	// Placement is the initial dock: "left", "bottom" or "right".
	Placement string
	Order     int
	// Text is the literal content of a text window.
	Text string
	// Web is the package-relative entry document of a web window.
	Web string
	// Native is the host-rendered content of a native window; nil for the other kinds.
	Native *NativePanel
	// IconHost is the declared host icon ID ("database", "git", ...), empty when the window
	// declares none. Package resources are not read as icons.
	IconHost string
}

// NativePanel is a host-rendered tree or list of literal nodes, with actions that call plugin
// functions. The host draws every control; the plugin supplies only the data and the handlers.
type NativePanel struct {
	// Kind is "tree" or "list".
	Kind  string
	Nodes []NativeNode
	// Form is the declared form of a form panel; nil for tree and list panels.
	Form *NativeForm
	// Source, when set, supplies the nodes: a function of the plugin, called for the one detected instance
	// of a build system, instead of the literal Nodes.
	Source *NativeSource
	// Actions are the handlers the toolbar and context menu reference, by ID.
	Actions     []NativeAction
	Toolbar     []string
	ContextMenu []string
}

// NativeForm is a form panel's controls and buttons. Layout is the column count when the form declares
// one, else 1; the host lays the controls out in order.
type NativeForm struct {
	Controls []NativeControl
	Buttons  []NativeFormButton
	Columns  int
}

// NativeControl is one field of a form. Value is a string, a boolean or a number, by kind.
type NativeControl struct {
	ID          string
	Label       string
	Kind        string
	Value       any
	Placeholder string
	Enabled     bool
	Info        string
	Options     []NativeOption
	Rows        int
	Minimum     float64
	Maximum     float64
	Step        float64
	// OnCommit names the action a change of the field calls with every field's value; empty keeps the field local.
	OnCommit string
	// Span is how many of the form's columns the field takes; 1 when the form declares no layout.
	Span int
}

// NativeOption is one choice of a select or segmented control.
type NativeOption struct {
	ID    string
	Label string
}

// NativeFormButton is a button of a form that runs a declared action with the form's values.
type NativeFormButton struct {
	ID      string
	Label   string
	Action  string
	Primary bool
	Enabled bool
}

// NativeSource names the build system whose single instance a source panel reads, and the function that
// returns its nodes.
type NativeSource struct {
	BuildSystemID string
	Function      string
}

// NativeNode is one row of a native panel.
type NativeNode struct {
	ID       string
	Label    string
	Children []NativeNode
}

// NativeAction is one handler of a native panel. Refresh redraws the panel; invoke calls Function with
// the selected node's ID.
type NativeAction struct {
	ID                string
	Title             string
	Kind              string
	RequiresSelection bool
	Function          string
}

// Native schema limits, from the contract's native schema 1.
const (
	maxNativeNodes  = 2000
	maxNativeDepth  = 16
	maxNativeAction = 64
)

// nativeIDPattern reports whether an ID is ASCII letters, digits or "._-" within 128 bytes.
func validNativeID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}

// decodeNativePanel validates a native declaration against the schema limits. A declaration that
// breaks them is refused as a whole; the other windows of the plugin still load.
func decodeNativePanel(raw json.RawMessage) (*NativePanel, error) {
	var declared struct {
		Kind    string            `json:"kind"`
		Nodes   []json.RawMessage `json:"nodes"`
		Actions []struct {
			ID                string `json:"id"`
			Title             string `json:"title"`
			Kind              string `json:"kind"`
			RequiresSelection bool   `json:"requiresSelection"`
			Function          string `json:"function"`
		} `json:"actions"`
		Toolbar []struct {
			Action string `json:"action"`
		} `json:"toolbar"`
		ContextMenu []string `json:"contextMenu"`
		Source      *struct {
			BuildSystemID string `json:"buildSystemID"`
			Function      string `json:"function"`
		} `json:"source"`
	}
	if err := json.Unmarshal(raw, &declared); err != nil {
		return nil, err
	}
	if declared.Kind == "form" {
		return decodeNativeForm(raw, declared.Actions, declared.Source != nil)
	}
	if declared.Kind != "tree" && declared.Kind != "list" {
		return nil, fmt.Errorf("native kind %q is not supported", declared.Kind)
	}
	if len(declared.Actions) > maxNativeAction {
		return nil, errors.New("a native panel declares too many actions")
	}
	panel := &NativePanel{Kind: declared.Kind}
	count := 0
	nodes, err := decodeNativeNodes(declared.Nodes, 0, &count, declared.Kind == "list")
	if err != nil {
		return nil, err
	}
	panel.Nodes = nodes
	if declared.Source != nil {
		if strings.TrimSpace(declared.Source.BuildSystemID) == "" || !validFunctionID(declared.Source.Function) {
			return nil, errors.New("a native source names a build system and a function ID")
		}
		panel.Source = &NativeSource{BuildSystemID: declared.Source.BuildSystemID, Function: declared.Source.Function}
	}
	actions := map[string]bool{}
	for _, action := range declared.Actions {
		if !validNativeID(action.ID) || action.Title == "" {
			return nil, errors.New("a native action needs a valid ID and a title")
		}
		if actions[action.ID] {
			return nil, fmt.Errorf("native action %q is declared twice", action.ID)
		}
		actions[action.ID] = true
		switch action.Kind {
		case "refresh":
			if action.RequiresSelection || action.Function != "" {
				return nil, errors.New("a refresh action selects nothing and names no function")
			}
		case "invoke":
			if !validFunctionID(action.Function) {
				return nil, errors.New("an invoke action names a function ID")
			}
		default:
			return nil, fmt.Errorf("native action kind %q is not supported", action.Kind)
		}
		panel.Actions = append(panel.Actions, NativeAction{ID: action.ID, Title: action.Title, Kind: action.Kind, RequiresSelection: action.RequiresSelection, Function: action.Function})
	}
	for _, entry := range declared.Toolbar {
		if !actions[entry.Action] {
			return nil, fmt.Errorf("the toolbar names the undeclared action %q", entry.Action)
		}
		panel.Toolbar = append(panel.Toolbar, entry.Action)
	}
	for _, id := range declared.ContextMenu {
		if !actions[id] {
			return nil, fmt.Errorf("the context menu names the undeclared action %q", id)
		}
		panel.ContextMenu = append(panel.ContextMenu, id)
	}
	return panel, nil
}

// decodeNativeNodes reads a node list. Nodes need a valid ID and a non-blank label of at most 1024 bytes.
// A list takes no children; the whole tree stays within the node and depth limits.
func decodeNativeNodes(raw []json.RawMessage, depth int, count *int, flat bool) ([]NativeNode, error) {
	if depth > maxNativeDepth {
		return nil, errors.New("a native panel nests deeper than the limit")
	}
	var nodes []NativeNode
	for _, item := range raw {
		var declared struct {
			ID       string            `json:"id"`
			Label    string            `json:"label"`
			Children []json.RawMessage `json:"children"`
		}
		if err := json.Unmarshal(item, &declared); err != nil {
			return nil, err
		}
		*count++
		if *count > maxNativeNodes {
			return nil, errors.New("a native panel has too many nodes")
		}
		if !validNativeID(declared.ID) || strings.TrimSpace(declared.Label) == "" || len(declared.Label) > 1024 {
			return nil, errors.New("a native node needs a valid ID and a label")
		}
		if flat && len(declared.Children) > 0 {
			return nil, errors.New("a native list takes no children")
		}
		children, err := decodeNativeNodes(declared.Children, depth+1, count, flat)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, NativeNode{ID: declared.ID, Label: declared.Label, Children: children})
	}
	return nodes, nil
}

// ToolWindows reads the tool windows of every enabled plugin, ordered by
// plugin ID, then by the declared order and ID. A broken manifest is
// reported without hiding the others.
func (s *Service) ToolWindows(ctx context.Context, entries []pluginmanager.Entry) ([]ToolWindow, error) {
	var windows []ToolWindow
	var failures []error
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	if selectionErr != nil {
		failures = append(failures, selectionErr)
	}
	sort.Slice(selected, func(i, j int) bool { return selected[i].Installed.ID < selected[j].Installed.ID })
	for _, entry := range selected {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		var declared struct {
			DisplayName string `json:"displayName"`
			UI          struct {
				ToolWindows []struct {
					ID        string          `json:"id"`
					Title     string          `json:"title"`
					Placement string          `json:"placement"`
					Order     int             `json:"order"`
					Text      string          `json:"text"`
					Native    json.RawMessage `json:"native"`
					Web       *struct {
						Entry string `json:"entry"`
					} `json:"web"`
					Icon *struct {
						Host string `json:"host"`
					} `json:"icon"`
				} `json:"toolWindows"`
			} `json:"ui"`
		}
		if err := json.Unmarshal(manifest, &declared); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		first := len(windows)
		for _, window := range declared.UI.ToolWindows {
			if window.ID == "" {
				failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, errors.New("a tool window has no id")))
				continue
			}
			declaredWindow := ToolWindow{
				PluginID: entry.Installed.ID, PluginName: declared.DisplayName, Package: entry.Installed.Path, Manifest: manifest,
				ID: window.ID, Title: window.Title, Placement: window.Placement, Order: window.Order, Text: window.Text,
			}
			if window.Web != nil {
				declaredWindow.Web = window.Web.Entry
			}
			if window.Icon != nil {
				declaredWindow.IconHost = window.Icon.Host
			}
			if len(window.Native) > 0 {
				panel, err := decodeNativePanel(window.Native)
				if err != nil {
					failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
					continue
				}
				declaredWindow.Native = panel
			}
			windows = append(windows, declaredWindow)
		}
		own := windows[first:]
		sort.SliceStable(own, func(i, j int) bool {
			if own[i].Order != own[j].Order {
				return own[i].Order < own[j].Order
			}
			return own[i].ID < own[j].ID
		})
	}
	return windows, errors.Join(failures...)
}

// decodeNativeForm reads a form declaration against the schema: at most 32 controls and 16 buttons, unique
// IDs, a literal label, a known kind, options for the choice kinds, and bounds for the stepper. A button
// names a declared action that selects nothing. A form declares no nodes and no source.
func decodeNativeForm(raw json.RawMessage, actions []struct {
	ID                string `json:"id"`
	Title             string `json:"title"`
	Kind              string `json:"kind"`
	RequiresSelection bool   `json:"requiresSelection"`
	Function          string `json:"function"`
}, hasSource bool) (*NativePanel, error) {
	var declared struct {
		Nodes  []json.RawMessage `json:"nodes"`
		Layout *struct {
			Columns int `json:"columns"`
		} `json:"layout"`
		Controls []struct {
			ID          string `json:"id"`
			Label       string `json:"label"`
			Kind        string `json:"kind"`
			Value       any    `json:"value"`
			Placeholder string `json:"placeholder"`
			Enabled     *bool  `json:"enabled"`
			Info        string `json:"info"`
			Options     []struct {
				ID    string `json:"id"`
				Label string `json:"label"`
			} `json:"options"`
			Rows     int      `json:"rows"`
			Minimum  *float64 `json:"minimum"`
			Maximum  *float64 `json:"maximum"`
			Step     *float64 `json:"step"`
			OnCommit string   `json:"onCommit"`
			Span     int      `json:"span"`
		} `json:"controls"`
		Buttons []struct {
			ID      string `json:"id"`
			Label   string `json:"label"`
			Action  string `json:"action"`
			Primary bool   `json:"primary"`
			Enabled *bool  `json:"enabled"`
		} `json:"buttons"`
	}
	if err := json.Unmarshal(raw, &declared); err != nil {
		return nil, err
	}
	if len(declared.Nodes) != 0 || hasSource {
		return nil, errors.New("a form declares no nodes and no source")
	}
	if len(declared.Controls) > 32 || len(declared.Buttons) > 16 || len(declared.Controls)+len(declared.Buttons) == 0 {
		return nil, errors.New("a form needs one to 32 controls and at most 16 buttons")
	}
	columns := 1
	if declared.Layout != nil {
		if declared.Layout.Columns < 1 || declared.Layout.Columns > 12 {
			return nil, errors.New("a form layout has one to 12 columns")
		}
		columns = declared.Layout.Columns
	}
	form := &NativeForm{Columns: columns}
	ids := map[string]bool{}
	for _, control := range declared.Controls {
		if !validNativeID(control.ID) || ids[control.ID] || strings.TrimSpace(control.Label) == "" || len(control.Label) > 256 {
			return nil, errors.New("a form control needs a unique valid ID and a label")
		}
		ids[control.ID] = true
		item := NativeControl{ID: control.ID, Label: control.Label, Kind: control.Kind, Value: control.Value, Placeholder: control.Placeholder, Enabled: control.Enabled == nil || *control.Enabled, Info: control.Info, OnCommit: control.OnCommit, Span: 1}
		if control.Kind == "editor" && control.OnCommit != "" {
			return nil, errors.New("an editor control takes no onCommit")
		}
		if declared.Layout == nil && control.Span != 0 {
			return nil, errors.New("a span needs the form's layout")
		}
		if declared.Layout != nil {
			if control.Span == 0 {
				item.Span = columns
			} else if control.Span < 1 || control.Span > columns {
				return nil, errors.New("a control's span is outside the form's columns")
			} else {
				item.Span = control.Span
			}
		}
		switch control.Kind {
		case "input", "search", "editor":
			if _, ok := control.Value.(string); !ok && control.Value != nil {
				return nil, fmt.Errorf("the %s control %q takes a string", control.Kind, control.ID)
			}
			if control.Kind == "editor" {
				item.Rows = control.Rows
				if item.Rows == 0 {
					item.Rows = 4
				}
				if item.Rows < 2 || item.Rows > 12 {
					return nil, errors.New("an editor control has two to 12 rows")
				}
			}
		case "select", "segmented":
			if len(control.Options) == 0 || (control.Kind == "segmented" && len(control.Options) > 8) || len(control.Options) > 128 {
				return nil, fmt.Errorf("the %s control %q needs options within the limits", control.Kind, control.ID)
			}
			for _, option := range control.Options {
				if !validNativeID(option.ID) || strings.TrimSpace(option.Label) == "" {
					return nil, errors.New("a form option needs a valid ID and a label")
				}
				item.Options = append(item.Options, NativeOption{ID: option.ID, Label: option.Label})
			}
			if text, ok := control.Value.(string); !ok || !slices.ContainsFunc(item.Options, func(o NativeOption) bool { return o.ID == text }) {
				return nil, fmt.Errorf("the %s control %q takes one of its options", control.Kind, control.ID)
			}
		case "checkbox":
			if _, ok := control.Value.(bool); !ok {
				return nil, fmt.Errorf("the checkbox control %q takes a boolean", control.ID)
			}
		case "stepper":
			number, ok := control.Value.(float64)
			if !ok || control.Minimum == nil || control.Maximum == nil || control.Step == nil || *control.Step <= 0 {
				return nil, fmt.Errorf("the stepper control %q needs a number, bounds and a positive step", control.ID)
			}
			if number < *control.Minimum || number > *control.Maximum {
				return nil, fmt.Errorf("the stepper control %q is outside its bounds", control.ID)
			}
			item.Minimum, item.Maximum, item.Step = *control.Minimum, *control.Maximum, *control.Step
		default:
			return nil, fmt.Errorf("the form control kind %q is not supported", control.Kind)
		}
		form.Controls = append(form.Controls, item)
	}
	declaredActions := map[string]struct {
		kind     string
		selects  bool
		function string
	}{}
	for _, action := range actions {
		declaredActions[action.ID] = struct {
			kind     string
			selects  bool
			function string
		}{action.Kind, action.RequiresSelection, action.Function}
	}
	for index := range form.Controls {
		commit := form.Controls[index].OnCommit
		if commit == "" {
			continue
		}
		target, ok := declaredActions[commit]
		if !ok || target.selects || target.kind != "invoke" {
			return nil, fmt.Errorf("the onCommit of %q names no declared invoke action that selects nothing", form.Controls[index].ID)
		}
	}
	for _, button := range declared.Buttons {
		if !validNativeID(button.ID) || ids[button.ID] || strings.TrimSpace(button.Label) == "" {
			return nil, errors.New("a form button needs a unique valid ID and a label")
		}
		ids[button.ID] = true
		target, ok := declaredActions[button.Action]
		if !ok || target.selects {
			return nil, fmt.Errorf("the button %q names no declared action that selects nothing", button.ID)
		}
		form.Buttons = append(form.Buttons, NativeFormButton{ID: button.ID, Label: button.Label, Action: button.Action, Primary: button.Primary, Enabled: button.Enabled == nil || *button.Enabled})
	}
	panel := &NativePanel{Kind: "form", Form: form}
	for _, action := range actions {
		panel.Actions = append(panel.Actions, NativeAction{ID: action.ID, Title: action.Title, Kind: action.Kind, RequiresSelection: action.RequiresSelection, Function: action.Function})
	}
	return panel, nil
}
