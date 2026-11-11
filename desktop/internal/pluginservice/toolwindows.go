package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
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
}

// NativePanel is a host-rendered tree or list of literal nodes, with actions that call plugin
// functions. The host draws every control; the plugin supplies only the data and the handlers.
type NativePanel struct {
	// Kind is "tree" or "list".
	Kind  string
	Nodes []NativeNode
	// Source, when set, supplies the nodes: a function of the plugin, called for the one detected instance
	// of a build system, instead of the literal Nodes.
	Source *NativeSource
	// Actions are the handlers the toolbar and context menu reference, by ID.
	Actions     []NativeAction
	Toolbar     []string
	ContextMenu []string
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
