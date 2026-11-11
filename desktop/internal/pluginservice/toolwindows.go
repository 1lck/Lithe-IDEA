package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"

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
					ID        string `json:"id"`
					Title     string `json:"title"`
					Placement string `json:"placement"`
					Order     int    `json:"order"`
					Text      string `json:"text"`
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
